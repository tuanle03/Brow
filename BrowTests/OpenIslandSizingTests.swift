import XCTest
@testable import Brow

/// Covers the pure auto-height sizing logic backing the opened AI panel:
/// grow with measured content, cap so the panel never exceeds the window,
/// and stay intrinsic (nil) until content has actually been laid out.
final class OpenIslandSizingTests: XCTestCase {
    func testUnmeasuredContentReturnsNil() {
        XCTAssertNil(openIslandContentHeight(measured: 0, cap: 520))
        XCTAssertNil(openIslandContentHeight(measured: -8, cap: 520))
    }

    func testShortContentUsesItsOwnHeight() {
        // Two options: compact panel, well under the cap.
        XCTAssertEqual(openIslandContentHeight(measured: 140, cap: 520), 140)
    }

    func testTallContentIsCapped() {
        // 50 options: content far exceeds the cap → clamp to the cap (scrolls).
        XCTAssertEqual(openIslandContentHeight(measured: 4_000, cap: 520), 520)
    }

    func testContentExactlyAtCapIsNotClamped() {
        XCTAssertEqual(openIslandContentHeight(measured: 520, cap: 520), 520)
    }

    func testWindowIsTallEnoughForTheCap() {
        // The window must physically contain the capped panel + shadow.
        XCTAssertGreaterThanOrEqual(windowSize.height, maxOpenNotchHeight + shadowPadding)
    }
}
