import Foundation

/// Runtime hints captured at hook-invocation time (impossible from inline curl).
struct HookRuntimeContext: Codable {
    var terminalApp: String?
    var tty: String?
    var terminalSessionID: String?
    var cwd: String?

    static func capture(environment: [String: String] = ProcessInfo.processInfo.environment) -> HookRuntimeContext {
        HookRuntimeContext(
            terminalApp: environment["TERM_PROGRAM"] ?? environment["__CFBundleIdentifier"],
            tty: environment["TTY"] ?? currentTTY(),
            terminalSessionID: environment["TERM_SESSION_ID"] ?? environment["ITERM_SESSION_ID"],
            cwd: FileManager.default.currentDirectoryPath
        )
    }

    private static func currentTTY() -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard ttyname_r(STDERR_FILENO, &buf, buf.count) == 0 else { return nil }
        return String(cString: buf)
    }
}
