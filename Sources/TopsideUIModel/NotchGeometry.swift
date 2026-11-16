import CoreGraphics

/// What the island needs to know about a screen. Read from `NSScreen` by the
/// app; kept as plain values here so the geometry can be tested without one.
/// Coordinates are AppKit's global ones (origin bottom-left of the primary screen).
public struct ScreenMetrics: Sendable, Equatable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `safeAreaInsets.top`: the notch height, 0 on screens without one.
    public var safeAreaTop: CGFloat
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: the menu bar either side of the notch.
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat = 0,
                auxiliaryTopLeft: CGRect? = nil, auxiliaryTopRight: CGRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }
}

/// Where the island goes on one screen (design doc 8.7).
///
/// The window never resizes: it is a fixed, transparent canvas hanging from
/// the top of the screen, and the island's shapes animate inside it. Only the
/// island's own rectangle takes the mouse; the rest lets clicks through.
public struct NotchGeometry: Sendable, Equatable {
    /// Width of each "ear" either side of the notch in the collapsed island.
    public static let earWidth: CGFloat = 64
    /// The collapsed pill on screens without a notch stands in for one this wide.
    public static let virtualNotchWidth: CGFloat = 96
    /// Menu bar height to assume when it is hidden (full-screen apps, auto-hide).
    public static let fallbackBarHeight: CGFloat = 24
    /// The canvas: as large as the largest shape (the expanded list), plus room for its shadow.
    public static let canvasSize = CGSize(width: 680, height: 640)

    public let screenFrame: CGRect
    /// 0 when the screen has no notch.
    public let notchWidth: CGFloat
    /// The notch height, or the menu bar height on screens without a notch.
    public let topBarHeight: CGFloat
    /// Horizontal centre of the notch (the screen's centre without one).
    public let centerX: CGFloat

    public var hasNotch: Bool { notchWidth > 0 }

    public init(_ m: ScreenMetrics) {
        screenFrame = m.frame
        if m.safeAreaTop > 0, let left = m.auxiliaryTopLeft, let right = m.auxiliaryTopRight,
           right.minX > left.maxX {
            notchWidth = right.minX - left.maxX
            centerX = (left.maxX + right.minX) / 2
            topBarHeight = m.safeAreaTop
        } else {
            notchWidth = 0
            centerX = m.frame.midX
            let menuBar = m.frame.maxY - m.visibleFrame.maxY
            topBarHeight = menuBar > 0 ? menuBar : Self.fallbackBarHeight
        }
    }

    /// Size of the collapsed island: the notch (real or virtual) plus two ears.
    public var collapsedSize: CGSize {
        CGSize(width: (hasNotch ? notchWidth : Self.virtualNotchWidth) + Self.earWidth * 2, height: topBarHeight)
    }

    /// The window's frame, centred on the notch and touching the top of the screen.
    /// Kept inside the screen horizontally so a notch near an edge cannot push it off.
    public var canvasFrame: CGRect {
        let size = CGSize(width: min(Self.canvasSize.width, screenFrame.width),
                          height: min(Self.canvasSize.height, screenFrame.height))
        var x = centerX - size.width / 2
        x = max(screenFrame.minX, min(x, screenFrame.maxX - size.width))
        return CGRect(x: x, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// An island shape of `size`, hanging from the top of the screen, centred on the notch.
    public func islandRect(size: CGSize) -> CGRect {
        let canvas = canvasFrame
        let w = min(size.width, canvas.width)
        let h = min(size.height, canvas.height)
        let x = max(canvas.minX, min(centerX - w / 2, canvas.maxX - w))
        return CGRect(x: x, y: screenFrame.maxY - h, width: w, height: h)
    }

    /// Horizontal offset of the notch's centre from the canvas's centre (non-zero
    /// only when the canvas had to be pushed back inside the screen).
    public var notchOffsetInCanvas: CGFloat { centerX - canvasFrame.midX }

    /// Whether a point (global coordinates) is over the island of `size`,
    /// with a little slop so the edge is easy to hit.
    public func contains(_ point: CGPoint, islandSize size: CGSize, slop: CGFloat = 4) -> Bool {
        islandRect(size: size).insetBy(dx: -slop, dy: -slop).contains(point)
    }
}
