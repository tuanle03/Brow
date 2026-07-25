import XCTest
@testable import Brow

final class AgentBridgeEnvelopeTests: XCTestCase {
    func testParsesSourceAndPayload() throws {
        let json = #"{"source":"claude","payload":{"hook_event_name":"Stop","session_id":"s1"},"context":{"tty":"/dev/ttys003"}}"#
        let env = try AgentBridgeEnvelope.decode(Data(json.utf8))
        XCTAssertEqual(env.source, "claude")
        XCTAssertEqual(env.context?.tty, "/dev/ttys003")
        XCTAssertEqual(env.payloadJSON["session_id"] as? String, "s1")
    }
}
