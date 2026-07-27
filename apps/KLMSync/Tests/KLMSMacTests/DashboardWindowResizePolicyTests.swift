import AppKit
import XCTest
@testable import KLMSMac

final class DashboardWindowResizePolicyTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testDetectsEveryInnerEdgeAndCorner() {
        let cases: [(CGPoint, KLMSDashboardResizeEdge)] = [
            (CGPoint(x: 1, y: 300), .left),
            (CGPoint(x: 799, y: 300), .right),
            (CGPoint(x: 400, y: 599), .top),
            (CGPoint(x: 400, y: 1), .bottom),
            (CGPoint(x: 1, y: 599), .topLeft),
            (CGPoint(x: 799, y: 599), .topRight),
            (CGPoint(x: 1, y: 1), .bottomLeft),
            (CGPoint(x: 799, y: 1), .bottomRight),
        ]

        for (point, expectedEdge) in cases {
            XCTAssertEqual(
                KLMSDashboardResizePolicy.edge(at: point, in: bounds),
                expectedEdge,
                "Unexpected resize edge for point \(point)"
            )
        }
    }

    func testCenterAndInteriorControlsRemainOutsideResizeHitArea() {
        XCTAssertNil(
            KLMSDashboardResizePolicy.edge(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                in: bounds
            )
        )
        XCTAssertNil(
            KLMSDashboardResizePolicy.edge(
                at: CGPoint(x: 100, y: 100),
                in: bounds
            )
        )
        XCTAssertNil(
            KLMSDashboardResizePolicy.edge(
                at: CGPoint(x: -1, y: bounds.midY),
                in: bounds
            )
        )
    }

    func testDefaultHitThicknessIncludesTwelvePointInnerBoundaryOnly() {
        XCTAssertEqual(KLMSDashboardResizePolicy.defaultHitThickness, 12)
        XCTAssertEqual(
            KLMSDashboardResizePolicy.edge(
                at: CGPoint(x: bounds.maxX - 12, y: bounds.midY),
                in: bounds
            ),
            .right
        )
        XCTAssertNil(
            KLMSDashboardResizePolicy.edge(
                at: CGPoint(x: bounds.maxX - 12.01, y: bounds.midY),
                in: bounds
            )
        )
    }

    @MainActor
    func testOverlayOnlyHitTestsInnerEdgeWhenWindowCanResize() {
        let window = DashboardResizeTestWindow(
            contentRect: bounds,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: bounds)
        window.contentView = contentView
        let overlay = KLMSDashboardWindowResizeOverlay()
        overlay.frame = contentView.bounds
        contentView.addSubview(overlay)

        XCTAssertTrue(overlay.hitTest(CGPoint(x: 10, y: bounds.midY)) === overlay)
        XCTAssertNil(overlay.hitTest(CGPoint(x: bounds.midX, y: bounds.midY)))

        window.styleMask.remove(.resizable)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 10, y: bounds.midY)))

        window.styleMask.insert(.resizable)
        window.reportedStyleMask = window.styleMask.union(.fullScreen)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 10, y: bounds.midY)))
    }

    func testLiveFrameDeltaMovesSelectedCornerAndKeepsOppositeCornerFixed() {
        let initial = CGRect(x: 100, y: 200, width: 800, height: 600)
        let resized = KLMSDashboardResizePolicy.resizedFrame(
            from: initial,
            edge: .bottomLeft,
            translation: CGSize(width: 40, height: 30),
            minimumSize: CGSize(width: 640, height: 520)
        )

        XCTAssertEqual(resized, CGRect(x: 140, y: 230, width: 760, height: 570))
        XCTAssertEqual(resized.maxX, initial.maxX)
        XCTAssertEqual(resized.maxY, initial.maxY)
    }

    func testMinimumSizeClampStopsMovingInnerEdge() {
        let initial = CGRect(x: 100, y: 200, width: 800, height: 600)
        let resized = KLMSDashboardResizePolicy.resizedFrame(
            from: initial,
            edge: .bottomLeft,
            translation: CGSize(width: 1_000, height: 1_000),
            minimumSize: CGSize(width: 640, height: 520)
        )

        XCTAssertEqual(resized, CGRect(x: 260, y: 280, width: 640, height: 520))
        XCTAssertEqual(resized.maxX, initial.maxX)
        XCTAssertEqual(resized.maxY, initial.maxY)
    }
}

@MainActor
private final class DashboardResizeTestWindow: NSWindow {
    var reportedStyleMask: NSWindow.StyleMask?

    override var styleMask: NSWindow.StyleMask {
        get { reportedStyleMask ?? super.styleMask }
        set { super.styleMask = newValue }
    }
}
