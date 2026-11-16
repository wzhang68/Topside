import CoreGraphics
import Testing
@testable import TopsideUIModel

@Suite struct NotchGeometryTests {
    // A 14" MacBook Pro: 1512×982pt, notch 185pt wide and 32pt high (values as NSScreen reports them).
    static let builtIn = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))

    // The external display M0 checked: 2560×1440pt, menu bar 25pt, no notch.
    static let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415))

    @Test func notchedScreen() {
        let g = NotchGeometry(Self.builtIn)
        #expect(g.hasNotch)
        #expect(g.notchWidth == 185)
        #expect(g.topBarHeight == 32)
        #expect(g.centerX == 756)
        #expect(g.collapsedSize == CGSize(width: 185 + 2 * NotchGeometry.earWidth, height: 32))
        // The collapsed island wraps the notch exactly, centred on it.
        let r = g.islandRect(size: g.collapsedSize)
        #expect(r.minX == 663.5 - NotchGeometry.earWidth)
        #expect(r.maxY == 982)
    }

    @Test func screenWithoutNotchUsesMenuBarHeightAndVirtualNotch() {
        let g = NotchGeometry(Self.external)
        #expect(!g.hasNotch)
        #expect(g.topBarHeight == 25)
        #expect(g.centerX == 1280)
        #expect(g.collapsedSize.width == NotchGeometry.virtualNotchWidth + 2 * NotchGeometry.earWidth)
    }

    @Test func hiddenMenuBarFallsBack() {
        let m = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(NotchGeometry(m).topBarHeight == NotchGeometry.fallbackBarHeight)
    }

    @Test func secondaryScreenUsesItsOwnCoordinates() {
        // A display placed to the left of and above the primary one.
        let m = ScreenMetrics(frame: CGRect(x: -1920, y: 982, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: -1920, y: 982, width: 1920, height: 1055))
        let g = NotchGeometry(m)
        #expect(g.centerX == -960)
        #expect(g.canvasFrame.maxY == 2062)
        #expect(g.canvasFrame.midX == -960)
        #expect(g.islandRect(size: CGSize(width: 200, height: 25)) == CGRect(x: -1060, y: 2037, width: 200, height: 25))
    }

    @Test func canvasHangsFromTheTopAndFitsSmallScreens() {
        let g = NotchGeometry(Self.builtIn)
        #expect(g.canvasFrame.maxY == 982)
        #expect(g.canvasFrame.size == NotchGeometry.canvasSize)
        let tiny = NotchGeometry(ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 500, height: 400),
                                               visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 375)))
        #expect(tiny.canvasFrame == CGRect(x: 0, y: 0, width: 500, height: 400))
        // An island larger than the canvas is clipped to it.
        #expect(tiny.islandRect(size: CGSize(width: 900, height: 900)) == tiny.canvasFrame)
    }

    @Test func hitTestingCoversOnlyTheIsland() {
        let g = NotchGeometry(Self.external)
        let size = CGSize(width: 520, height: 300)
        #expect(g.contains(CGPoint(x: 1280, y: 1430), islandSize: size))
        #expect(g.contains(CGPoint(x: 1280 - 262, y: 1430), islandSize: size))       // within the slop
        #expect(!g.contains(CGPoint(x: 1280 - 270, y: 1430), islandSize: size))
        #expect(!g.contains(CGPoint(x: 1280, y: 1440 - 310), islandSize: size))      // below it, still on the canvas
    }
}
