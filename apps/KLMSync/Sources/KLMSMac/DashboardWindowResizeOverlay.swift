import AppKit

enum KLMSDashboardResizeEdge: CaseIterable, Equatable, Sendable {
    case left
    case right
    case top
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    fileprivate var movesLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }

    fileprivate var movesRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }

    fileprivate var movesTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }

    fileprivate var movesBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
}

enum KLMSDashboardResizePolicy {
    static let defaultHitThickness: CGFloat = 12

    static func edge(
        at point: CGPoint,
        in bounds: CGRect,
        hitThickness: CGFloat = defaultHitThickness
    ) -> KLMSDashboardResizeEdge? {
        guard bounds.width > 0,
              bounds.height > 0,
              point.x >= bounds.minX,
              point.x <= bounds.maxX,
              point.y >= bounds.minY,
              point.y <= bounds.maxY else {
            return nil
        }
        let thickness = effectiveHitThickness(hitThickness, in: bounds)
        guard thickness > 0 else { return nil }

        let isLeft = point.x <= bounds.minX + thickness
        let isRight = point.x >= bounds.maxX - thickness
        let isBottom = point.y <= bounds.minY + thickness
        let isTop = point.y >= bounds.maxY - thickness

        switch (isLeft, isRight, isTop, isBottom) {
        case (true, _, true, _):
            return .topLeft
        case (_, true, true, _):
            return .topRight
        case (true, _, _, true):
            return .bottomLeft
        case (_, true, _, true):
            return .bottomRight
        case (true, _, _, _):
            return .left
        case (_, true, _, _):
            return .right
        case (_, _, true, _):
            return .top
        case (_, _, _, true):
            return .bottom
        default:
            return nil
        }
    }

    static func cursorRect(
        for edge: KLMSDashboardResizeEdge,
        in bounds: CGRect,
        hitThickness: CGFloat = defaultHitThickness
    ) -> CGRect {
        let thickness = effectiveHitThickness(hitThickness, in: bounds)
        let horizontalLength = max(0, bounds.width - (2 * thickness))
        let verticalLength = max(0, bounds.height - (2 * thickness))

        switch edge {
        case .left:
            return CGRect(
                x: bounds.minX,
                y: bounds.minY + thickness,
                width: thickness,
                height: verticalLength
            )
        case .right:
            return CGRect(
                x: bounds.maxX - thickness,
                y: bounds.minY + thickness,
                width: thickness,
                height: verticalLength
            )
        case .top:
            return CGRect(
                x: bounds.minX + thickness,
                y: bounds.maxY - thickness,
                width: horizontalLength,
                height: thickness
            )
        case .bottom:
            return CGRect(
                x: bounds.minX + thickness,
                y: bounds.minY,
                width: horizontalLength,
                height: thickness
            )
        case .topLeft:
            return CGRect(
                x: bounds.minX,
                y: bounds.maxY - thickness,
                width: thickness,
                height: thickness
            )
        case .topRight:
            return CGRect(
                x: bounds.maxX - thickness,
                y: bounds.maxY - thickness,
                width: thickness,
                height: thickness
            )
        case .bottomLeft:
            return CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: thickness,
                height: thickness
            )
        case .bottomRight:
            return CGRect(
                x: bounds.maxX - thickness,
                y: bounds.minY,
                width: thickness,
                height: thickness
            )
        }
    }

    static func resizedFrame(
        from initialFrame: CGRect,
        edge: KLMSDashboardResizeEdge,
        translation: CGSize,
        minimumSize: CGSize,
        maximumSize: CGSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    ) -> CGRect {
        let minimumWidth = max(0, minimumSize.width)
        let minimumHeight = max(0, minimumSize.height)
        let maximumWidth = max(minimumWidth, finiteMaximum(maximumSize.width))
        let maximumHeight = max(minimumHeight, finiteMaximum(maximumSize.height))

        var frame = initialFrame
        if edge.movesLeft {
            frame.size.width = clamped(
                initialFrame.width - translation.width,
                minimum: minimumWidth,
                maximum: maximumWidth
            )
            frame.origin.x = initialFrame.maxX - frame.width
        } else if edge.movesRight {
            frame.size.width = clamped(
                initialFrame.width + translation.width,
                minimum: minimumWidth,
                maximum: maximumWidth
            )
        }

        if edge.movesBottom {
            frame.size.height = clamped(
                initialFrame.height - translation.height,
                minimum: minimumHeight,
                maximum: maximumHeight
            )
            frame.origin.y = initialFrame.maxY - frame.height
        } else if edge.movesTop {
            frame.size.height = clamped(
                initialFrame.height + translation.height,
                minimum: minimumHeight,
                maximum: maximumHeight
            )
        }
        return frame
    }

    private static func effectiveHitThickness(_ proposed: CGFloat, in bounds: CGRect) -> CGFloat {
        max(0, min(proposed, min(bounds.width, bounds.height) / 2))
    }

    private static func finiteMaximum(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : .greatestFiniteMagnitude
    }

    private static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}

@MainActor
final class KLMSDashboardWindowResizeOverlay: NSView {
    private struct DragState {
        var edge: KLMSDashboardResizeEdge
        var initialFrame: CGRect
        var initialMouseLocation: CGPoint
    }

    private let hitThickness: CGFloat
    private var dragState: DragState?

    init(hitThickness: CGFloat = KLMSDashboardResizePolicy.defaultHitThickness) {
        self.hitThickness = hitThickness
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard canResizeWindow,
              KLMSDashboardResizePolicy.edge(
                  at: point,
                  in: bounds,
                  hitThickness: hitThickness
              ) != nil else {
            return nil
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard canResizeWindow else { return }
        for edge in KLMSDashboardResizeEdge.allCases {
            let rect = KLMSDashboardResizePolicy.cursorRect(
                for: edge,
                in: bounds,
                hitThickness: hitThickness
            )
            guard !rect.isEmpty else { continue }
            addCursorRect(rect, cursor: Self.cursor(for: edge))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window,
              canResizeWindow,
              let edge = KLMSDashboardResizePolicy.edge(
                  at: convert(event.locationInWindow, from: nil),
                  in: bounds,
                  hitThickness: hitThickness
              ) else {
            return
        }
        dragState = DragState(
            edge: edge,
            initialFrame: window.frame,
            initialMouseLocation: window.convertPoint(toScreen: event.locationInWindow)
        )
        window.contentView?.viewWillStartLiveResize()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragState else { return }
        guard canResizeWindow else {
            finishDragging()
            return
        }
        let currentMouseLocation = window.convertPoint(toScreen: event.locationInWindow)
        let translation = CGSize(
            width: currentMouseLocation.x - dragState.initialMouseLocation.x,
            height: currentMouseLocation.y - dragState.initialMouseLocation.y
        )
        let frame = KLMSDashboardResizePolicy.resizedFrame(
            from: dragState.initialFrame,
            edge: dragState.edge,
            translation: translation,
            minimumSize: window.minSize,
            maximumSize: window.maxSize
        )
        window.setFrame(frame, display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        finishDragging()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            finishDragging()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private var canResizeWindow: Bool {
        guard let window else { return false }
        return window.styleMask.contains(.resizable)
            && !window.styleMask.contains(.fullScreen)
    }

    private func finishDragging() {
        guard dragState != nil else { return }
        dragState = nil
        window?.contentView?.viewDidEndLiveResize()
        window?.invalidateCursorRects(for: self)
    }

    private static func cursor(for edge: KLMSDashboardResizeEdge) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: edge.frameResizePosition, directions: .all)
        }
        switch edge {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .bottomRight:
            return northWestSouthEastCursor
        case .topRight, .bottomLeft:
            return northEastSouthWestCursor
        }
    }

    private static let northWestSouthEastCursor = diagonalCursor(descendsRight: true)
    private static let northEastSouthWestCursor = diagonalCursor(descendsRight: false)

    private static func diagonalCursor(descendsRight: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            let start = descendsRight ? NSPoint(x: 3, y: 15) : NSPoint(x: 3, y: 3)
            let end = descendsRight ? NSPoint(x: 15, y: 3) : NSPoint(x: 15, y: 15)
            path.move(to: start)
            path.line(to: end)
            if descendsRight {
                path.move(to: NSPoint(x: 3, y: 10))
                path.line(to: start)
                path.line(to: NSPoint(x: 8, y: 15))
                path.move(to: NSPoint(x: 10, y: 3))
                path.line(to: end)
                path.line(to: NSPoint(x: 15, y: 8))
            } else {
                path.move(to: NSPoint(x: 3, y: 8))
                path.line(to: start)
                path.line(to: NSPoint(x: 8, y: 3))
                path.move(to: NSPoint(x: 10, y: 15))
                path.line(to: end)
                path.line(to: NSPoint(x: 15, y: 10))
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return rect.width > 0
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }
}

@available(macOS 15.0, *)
private extension KLMSDashboardResizeEdge {
    var frameResizePosition: NSCursor.FrameResizePosition {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        case .top:
            return .top
        case .bottom:
            return .bottom
        case .topLeft:
            return .topLeft
        case .topRight:
            return .topRight
        case .bottomLeft:
            return .bottomLeft
        case .bottomRight:
            return .bottomRight
        }
    }
}
