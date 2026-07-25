import XCTest
@testable import Brow

final class ClaudeHookInstallCommandTests: XCTestCase {
    func testHookCommandWrapsBinaryPathWithSourceFlag() {
        let command = ClaudeCodeHookInstaller.hookCommand(binaryPath: "/tmp/x/BrowAgentHook")
        XCTAssertEqual(command, "'/tmp/x/BrowAgentHook' --source claude")
    }
}
