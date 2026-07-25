import Foundation

/// Owns the on-disk side of the Claude Code integration:
///
/// 1. Writes the small shell script Claude Code will exec on `PreToolUse` /
///    `Notification` to `~/.brow/hooks/brow-claude-hook`. The script just
///    forwards stdin to `ClaudeCodeBridge` over loopback and prints the
///    response back to stdout.
/// 2. Reads, mutates, and rewrites `~/.claude/settings.json` so Claude Code
///    knows to call that script. We append our hook entry rather than
///    overwriting, so existing user hooks (Masko's, custom scripts) keep
///    working. Uninstall removes only the entries whose `command` matches
///    the installed script path, again leaving everything else untouched.
///
/// All file IO is synchronous and runs off MainActor so the UI can call
/// install / uninstall from a Button action.
enum ClaudeCodeHookInstaller {

    /// Hook events Brow subscribes to:
    /// - `SessionStart` / `SessionEnd`: keep the Sessions list live, so the
    ///   notch knows Claude is running the instant a CLI session opens —
    ///   no waiting for the first permission prompt.
    /// - `UserPromptSubmit`: fires every time the user types and submits a
    ///   message. We use the latest one as the "You: …" subtitle in the
    ///   Monitor row so the task list reads like a TODO list of asks.
    /// - `PermissionRequest`: only fires when Claude Code would otherwise
    ///   show its native permission dialog, so the notch UI mirrors the
    ///   CLI 1:1 (no double-prompting on auto-allowed tools).
    /// - `Notification`: "Claude is waiting / idle" alerts.
    /// - `Stop`: Claude finished the current turn, drives the "done" toast.
    ///
    /// Install/uninstall sweep every hook key (not just these) for our
    /// command, so older Brow builds that wrote into `PreToolUse` get
    /// cleaned up automatically on the next install. **Existing Brow users
    /// need to re-run install for `UserPromptSubmit` to take effect.**
    static let coveredHooks: [String] = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PermissionRequest",
        "Notification",
        "Stop",
    ]

    enum InstallationState: Equatable {
        case notInstalled
        case installed
        /// Settings.json references our hook AND another tool's hook command
        /// at the same hook. Not strictly a conflict — Claude Code runs all
        /// matching hooks in parallel — but surface it so the user knows
        /// they might see double prompts.
        case installedWithSiblings(siblingCommands: [String])
    }

    enum InstallError: LocalizedError {
        case homeDirectoryUnavailable
        case scriptWriteFailed(underlying: Error)
        case settingsReadFailed(underlying: Error)
        case settingsParseFailed(reason: String)
        case settingsWriteFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .homeDirectoryUnavailable:
                return "Could not resolve the user's home directory."
            case .scriptWriteFailed(let e):
                return "Couldn't write the hook script: \(e.localizedDescription)"
            case .settingsReadFailed(let e):
                return "Couldn't read ~/.claude/settings.json: \(e.localizedDescription)"
            case .settingsParseFailed(let reason):
                return "~/.claude/settings.json is not valid JSON: \(reason)"
            case .settingsWriteFailed(let e):
                return "Couldn't write ~/.claude/settings.json: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Paths

    /// Real user home — `NSHomeDirectory()` returns the sandbox container
    /// when Brow runs sandboxed, and Claude Code only reads the *actual*
    /// `~/.claude/settings.json`. `getpwuid` is not redirected by the
    /// sandbox so it gives us the host home path.
    static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Legacy path of the standalone hook script Brow used to write before
    /// switching to an inline `curl` command. Kept so uninstall can clean
    /// up the file written by older builds.
    static var hookScriptPath: String {
        (realHomeDirectory as NSString).appendingPathComponent(".brow/hooks/brow-claude-hook")
    }

    static var claudeSettingsPath: String {
        (realHomeDirectory as NSString).appendingPathComponent(".claude/settings.json")
    }

    /// Command Claude Code runs for each covered hook event: the managed
    /// `BrowAgentHook` binary (Task 0.2), which reads the hook payload from
    /// stdin, POSTs it to the local bridge, and prints the response back to
    /// stdout. Pure and testable — no filesystem access.
    static func hookCommand(binaryPath: String) -> String {
        "'\(binaryPath)' --source claude"
    }

    /// The hook command currently referenced in settings.json, based on the
    /// managed install path. Used for detection (`isOurCommand`) — doesn't
    /// require the binary to actually be installed. Also shown verbatim in
    /// the Settings → AI "Details" disclosure.
    static var currentHookCommand: String {
        hookCommand(binaryPath: ManagedHookBinary.installedURL.path)
    }

    // MARK: - Public API

    static func install() throws {
        let binaryPath = try ManagedHookBinary.ensureInstalled().path
        try mutateSettings { settings in
            attachOurHook(to: &settings, binaryPath: binaryPath)
        }
        removeLegacyHookScript()
    }

    static func uninstall() throws {
        try mutateSettings { settings in
            detachOurHook(from: &settings)
        }
        removeLegacyHookScript()
    }

    static func currentState() -> InstallationState {
        let settings = (try? loadSettings()) ?? [:]
        let referenced = settingsReferenceOurHook(settings)
        if !referenced { return .notInstalled }
        let siblings = siblingCommandsAlongsideOurs(in: settings)
        return siblings.isEmpty ? .installed : .installedWithSiblings(siblingCommands: siblings)
    }

    /// Best-effort cleanup of the on-disk hook script written by Brow
    /// builds prior to the inline-command switch. Quarantined or not, the
    /// file is no longer referenced from settings.json once `install` has
    /// run, so deleting it just keeps `~/.brow/hooks/` tidy. Failures are
    /// silent — leftover orphan is harmless.
    private static func removeLegacyHookScript() {
        try? FileManager.default.removeItem(atPath: hookScriptPath)
    }

    // MARK: - settings.json mutations

    private typealias Settings = [String: Any]

    private static func mutateSettings(_ change: (inout Settings) -> Void) throws {
        var settings = try loadSettings()
        change(&settings)
        try writeSettings(settings)
    }

    private static func loadSettings() throws -> Settings {
        let path = claudeSettingsPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [:] }
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw InstallError.settingsReadFailed(underlying: error)
        }
        if data.isEmpty { return [:] }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let dict = object as? [String: Any] else {
                throw InstallError.settingsParseFailed(reason: "Top-level value is not an object.")
            }
            return dict
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.settingsParseFailed(reason: error.localizedDescription)
        }
    }

    private static func writeSettings(_ settings: Settings) throws {
        let url = URL(fileURLWithPath: claudeSettingsPath)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw InstallError.settingsWriteFailed(underlying: error)
        }
    }

    /// Adds our hook entry under each covered hook name. Existing entries at
    /// the same hook key are preserved. Also sweeps legacy hook keys (e.g.
    /// the old PreToolUse entry) so we never leave a stale Brow reference
    /// behind after a hook-event migration.
    private static func attachOurHook(to settings: inout Settings, binaryPath: String) {
        var hooks = (settings["hooks"] as? Settings) ?? [:]

        // 1. Strip any existing Brow reference, anywhere in the hooks dict.
        sweepOurHook(from: &hooks)

        // 2. Re-attach under the currently-covered hook names.
        for hookName in coveredHooks {
            var bucket = (hooks[hookName] as? [Any]) ?? []
            bucket.append([
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": hookCommand(binaryPath: binaryPath)
                ]]
            ] as [String: Any])
            hooks[hookName] = bucket
        }
        settings["hooks"] = hooks
    }

    /// Identifies a hook entry as Brow's own — either the managed-binary
    /// command, or the legacy on-disk script path written by older builds.
    private static func isOurCommand(_ command: String) -> Bool {
        command == currentHookCommand || command == hookScriptPath
    }

    /// Removes only the hook entries whose nested `command` field matches
    /// our installed script path. Leaves everything else alone.
    private static func detachOurHook(from settings: inout Settings) {
        guard var hooks = settings["hooks"] as? Settings else { return }
        sweepOurHook(from: &hooks)
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
    }

    /// Removes every entry whose nested `command` field matches Brow's
    /// inline command or the legacy script path, across all hook event
    /// keys. Empty buckets get pruned. Mutates in place.
    private static func sweepOurHook(from hooks: inout Settings) {
        for hookName in Array(hooks.keys) {
            guard var bucket = hooks[hookName] as? [Any] else { continue }
            bucket.removeAll { entry in
                guard let dict = entry as? [String: Any],
                      let inner = dict["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { isOurCommand(($0["command"] as? String) ?? "") }
            }
            if bucket.isEmpty {
                hooks.removeValue(forKey: hookName)
            } else {
                hooks[hookName] = bucket
            }
        }
    }

    private static func settingsReferenceOurHook(_ settings: Settings) -> Bool {
        guard let hooks = settings["hooks"] as? Settings else { return false }
        for hookName in coveredHooks {
            guard let bucket = hooks[hookName] as? [Any] else { continue }
            for entry in bucket {
                guard let dict = entry as? [String: Any],
                      let inner = dict["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { isOurCommand(($0["command"] as? String) ?? "") }) {
                    return true
                }
            }
        }
        return false
    }

    /// Returns command paths of any *other* PermissionRequest / Notification
    /// hooks the user already has, so the Settings panel can surface "Masko
    /// is also installed" / "an extra hook from <path> is active".
    private static func siblingCommandsAlongsideOurs(in settings: Settings) -> [String] {
        guard let hooks = settings["hooks"] as? Settings else { return [] }
        var siblings: Set<String> = []
        for hookName in coveredHooks {
            guard let bucket = hooks[hookName] as? [Any] else { continue }
            for entry in bucket {
                guard let dict = entry as? [String: Any],
                      let inner = dict["hooks"] as? [[String: Any]] else { continue }
                for hook in inner {
                    if let command = hook["command"] as? String, !isOurCommand(command) {
                        siblings.insert(command)
                    }
                }
            }
        }
        return siblings.sorted()
    }
}

/// Manages the on-disk copy of the `BrowAgentHook` CLI binary embedded in
/// the app (Task 0.2, `Contents/Helpers/BrowAgentHook`). Claude Code execs
/// hook commands from *outside* the app sandbox, so the binary must live at
/// a stable, real-home path rather than inside `Brow.app` — the app bundle
/// can move or be re-signed between launches, and a path inside it would
/// break the hook until the next `install()`.
enum ManagedHookBinary {
    enum InstallError: LocalizedError {
        case bundledBinaryMissing

        var errorDescription: String? {
            "BrowAgentHook is missing from the app bundle."
        }
    }

    static var installedURL: URL {
        URL(fileURLWithPath: ClaudeCodeHookInstaller.realHomeDirectory)
            .appendingPathComponent("Library/Application Support/Brow/bin/BrowAgentHook")
    }

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "BrowAgentHook", withExtension: nil, subdirectory: "Helpers")
            ?? Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("../Helpers/BrowAgentHook").standardizedFileURL
    }

    /// Copies the bundled binary to the managed path if missing or changed,
    /// then makes sure it's executable. Returns the managed path.
    @discardableResult
    static func ensureInstalled() throws -> URL {
        guard let bundled = bundledURL, FileManager.default.fileExists(atPath: bundled.path) else {
            throw InstallError.bundledBinaryMissing
        }
        let installed = installedURL
        let fm = FileManager.default
        try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)

        let upToDate = fm.fileExists(atPath: installed.path)
            && (try? Data(contentsOf: bundled)) == (try? Data(contentsOf: installed))
        if !upToDate {
            try? fm.removeItem(at: installed)
            try fm.copyItem(at: bundled, to: installed)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        return installed
    }
}
