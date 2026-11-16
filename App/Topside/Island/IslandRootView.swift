import SwiftUI
import TopsideUIModel

enum IslandStyle {
    static let expandedWidth: CGFloat = 540
    static let launcherWidth: CGFloat = 600
    static let radius: CGFloat = 22
    static let collapsedRadius: CGFloat = 10
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Room the list may take: the canvas minus the top bar, footer and padding.
    static func maxListHeight(_ g: NotchGeometry) -> CGFloat {
        NotchGeometry.canvasSize.height - g.topBarHeight - 80
    }
}

/// The whole canvas: the island hangs from the top, the rest is transparent.
struct IslandRootView: View {
    @Bindable var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(x: model.geometry.notchOffsetInCanvas)
    }

    private var island: some View {
        content
            .background(shape.fill(Color.black))
            .clipShape(shape)
            .contentShape(shape)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.islandSize = $0 }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.addRepository(folder: url) }
                }
                return true
            }
            .animation(IslandStyle.spring, value: model.mode)
            .environment(\.colorScheme, .dark)
    }

    private var shape: UnevenRoundedRectangle {
        let r = model.mode == .collapsed ? IslandStyle.collapsedRadius : IslandStyle.radius
        return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .collapsed:
            CollapsedView(model: model)
                .frame(width: model.collapsedSize.width, height: model.collapsedSize.height)
                .onTapGesture { model.window?.expand(pinned: true) }
        case .expanded:
            ExpandedView(model: model)
                .frame(width: IslandStyle.expandedWidth)
        case .launcher:
            LauncherView(model: model)
                .frame(width: IslandStyle.launcherWidth)
        }
    }
}

/// ① Collapsed: running on the left; needs you, failed and ready on the right
/// (either side of the notch when there is one).
struct CollapsedView: View {
    let model: IslandModel

    var body: some View {
        let c = model.store.counts
        HStack(spacing: 0) {
            if c.active > 0 {
                Label("\(c.active)", systemImage: "circle.lefthalf.filled")
                    .padding(.leading, 12)
            }
            Spacer(minLength: model.geometry.hasNotch ? model.geometry.notchWidth : 8)
            HStack(spacing: 8) {
                if c.needsYou > 0 { Label("\(c.needsYou)", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                if c.failed > 0 { Label("\(c.failed)", systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                if c.ready > 0 { Label("\(c.ready)", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            .padding(.trailing, 12)
        }
        .labelStyle(CountLabelStyle())
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
    }
}

struct CountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
