import XCTest
@testable import Brow

final class ClaudeHookInstallCommandTests: XCTestCase {
    func testHookCommandWrapsBinaryPathWithSourceFlag() {
        let command = ClaudeCodeHookInstaller.hookCommand(binaryPath: "/tmp/x/BrowAgentHook")
        XCTAssertEqual(command, "'/tmp/x/BrowAgentHook' --source claude")
    }

    /// Every currently-installed Brow user has this exact inline-curl string
    /// in ~/.claude/settings.json from before the BrowAgentHook binary swap.
    /// If isOurCommand stops recognizing it, upgrade's install()/uninstall()
    /// silently leave it in place instead of sweeping it — the old curl hook
    /// and the new binary hook both fire per event.
    func testIsOurCommandRecognizesLegacyCurlCommand() {
        XCTAssertTrue(ClaudeCodeHookInstaller.isOurCommand(ClaudeCodeHookInstaller.legacyCurlCommand))
    }
}
