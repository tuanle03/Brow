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

    /// MVP hook coverage. Matches user's decision — `PreToolUse` for
    /// permission prompts + `Notification` for "Claude finished" badges.
    static let coveredHooks: [String] = ["PreToolUse", "Notification"]

    enum InstallationState: Equatable {
        case notInstalled
        case installed
        /// Settings.json references our path AND another tool's hook command
        /// at the same hook. Not strictly a conflict — Claude Code runs all
        /// matching hooks in parallel — but surface it so the user knows
        /// they might see double prompts.
        case installedWithSiblings(siblingCommands: [String])
        /// Our script is on disk but settings.json doesn't mention us.
        case scriptOrphaned
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

    static var hookScriptPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".brow/hooks/brow-claude-hook")
    }

    static var claudeSettingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Public API

    static func install() throws {
        try writeHookScript()
        try mutateSettings { settings in
            attachOurHook(to: &settings)
        }
    }

    static func uninstall() throws {
        try mutateSettings { settings in
            detachOurHook(from: &settings)
        }
        // Leave ~/.brow/hooks/brow-claude-hook on disk. It is harmless once
        // settings.json no longer references it, and keeping it avoids the
        // re-install having to re-prompt the user about TCC on write.
    }

    static func currentState() -> InstallationState {
        let scriptExists = FileManager.default.fileExists(atPath: hookScriptPath)
        let settings = (try? loadSettings()) ?? [:]
        let referenced = settingsReferenceOurHook(settings)

        if !scriptExists && !referenced { return .notInstalled }
        if scriptExists && !referenced { return .scriptOrphaned }

        let siblings = siblingCommandsAlongsideOurs(in: settings)
        if siblings.isEmpty {
            return .installed
        } else {
            return .installedWithSiblings(siblingCommands: siblings)
        }
    }

    // MARK: - Hook script

    /// The exact text Brow writes to `~/.brow/hooks/brow-claude-hook`. POSIX
    /// shell so it survives whatever shell environment Claude Code runs.
    /// Stdin → POST → stdout. Default to "ask" if Brow isn't running so the
    /// user still gets the native Claude Code prompt.
    static let hookScriptBody: String = #"""
    #!/bin/sh
    # Brow Claude Code hook bridge.
    # Forwards the hook's stdin JSON to the local Brow listener and
    # prints Brow's response to stdout so Claude Code can pick up the
    # permission decision.
    #
    # Managed by Brow.app — do not edit by hand. Re-install from
    # Brow > Settings > AI Sessions if this file gets out of date.

    set -e

    BROW_URL="http://127.0.0.1:21064/event"
    PAYLOAD=$(cat)

    if ! command -v curl >/dev/null 2>&1; then
        # No curl on PATH — let Claude Code prompt the user normally.
        exit 0
    fi

    RESPONSE=$(printf '%s' "$PAYLOAD" \
        | curl --silent --show-error --max-time 60 \
            -H 'Content-Type: application/json' \
            --data-binary @- \
            "$BROW_URL" 2>/dev/null) || RESPONSE=""

    if [ -n "$RESPONSE" ]; then
        printf '%s\n' "$RESPONSE"
    fi
    exit 0
    """#

    private static func writeHookScript() throws {
        let path = hookScriptPath
        let parent = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try hookScriptBody.write(toFile: path, atomically: true, encoding: .utf8)
            // chmod 755 so Claude Code can exec it.
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: path)
        } catch {
            throw InstallError.scriptWriteFailed(underlying: error)
        }
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
    /// the same hook key are preserved.
    private static func attachOurHook(to settings: inout Settings) {
        var hooks = (settings["hooks"] as? Settings) ?? [:]
        for hookName in coveredHooks {
            var bucket = (hooks[hookName] as? [Any]) ?? []
            bucket.removeAll { entry in
                // Drop any pre-existing Brow entry so re-install doesn't
                // duplicate. Detection is by matching command path.
                if let dict = entry as? [String: Any],
                   let inner = dict["hooks"] as? [[String: Any]] {
                    return inner.contains { ($0["command"] as? String) == hookScriptPath }
                }
                return false
            }
            bucket.append([
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": hookScriptPath
                ]]
            ] as [String: Any])
            hooks[hookName] = bucket
        }
        settings["hooks"] = hooks
    }

    /// Removes only the hook entries whose nested `command` field matches
    /// our installed script path. Leaves everything else alone.
    private static func detachOurHook(from settings: inout Settings) {
        guard var hooks = settings["hooks"] as? Settings else { return }
        for hookName in coveredHooks {
            guard var bucket = hooks[hookName] as? [Any] else { continue }
            bucket.removeAll { entry in
                guard let dict = entry as? [String: Any],
                      let inner = dict["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String) == hookScriptPath }
            }
            if bucket.isEmpty {
                hooks.removeValue(forKey: hookName)
            } else {
                hooks[hookName] = bucket
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
    }

    private static func settingsReferenceOurHook(_ settings: Settings) -> Bool {
        guard let hooks = settings["hooks"] as? Settings else { return false }
        for hookName in coveredHooks {
            guard let bucket = hooks[hookName] as? [Any] else { continue }
            for entry in bucket {
                guard let dict = entry as? [String: Any],
                      let inner = dict["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { ($0["command"] as? String) == hookScriptPath }) {
                    return true
                }
            }
        }
        return false
    }

    /// Returns command paths of any *other* PreToolUse / Notification hooks
    /// the user already has, so the Settings panel can surface "Masko is
    /// also installed" / "an extra hook from <path> is active".
    private static func siblingCommandsAlongsideOurs(in settings: Settings) -> [String] {
        guard let hooks = settings["hooks"] as? Settings else { return [] }
        var siblings: Set<String> = []
        for hookName in coveredHooks {
            guard let bucket = hooks[hookName] as? [Any] else { continue }
            for entry in bucket {
                guard let dict = entry as? [String: Any],
                      let inner = dict["hooks"] as? [[String: Any]] else { continue }
                for hook in inner {
                    if let command = hook["command"] as? String, command != hookScriptPath {
                        siblings.insert(command)
                    }
                }
            }
        }
        return siblings.sorted()
    }
}
