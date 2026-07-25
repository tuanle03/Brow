import Foundation

// Fail-open: any failure logs to stderr and exits 0 so the agent is never blocked.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[BrowAgentHook] \(message)\n".utf8))
    exit(0)
}

let args = CommandLine.arguments
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let source = flag("--source") ?? "claude"

let payload = FileHandle.standardInput.readDataToEndOfFile()
let context = HookRuntimeContext.capture()

// Interactive events wait up to 24h (Claude PermissionRequest), else 45s.
let isInteractive = String(data: payload, encoding: .utf8)?.contains("PermissionRequest") ?? false
    || String(data: payload, encoding: .utf8)?.contains("AskUserQuestion") ?? false
let timeout: TimeInterval = isInteractive ? 24 * 60 * 60 : 45

if let response = BridgePost.send(source: source, payload: payload, context: context, timeout: timeout),
   !response.isEmpty {
    FileHandle.standardOutput.write(response)
}
exit(0)
