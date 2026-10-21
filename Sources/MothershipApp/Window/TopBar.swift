import AppKit
import SwiftUI

/// The 52 pt top row with no background (§5): ⌂ and ◫ beside the traffic lights, the
/// Workspaces · Fleet pill centered, the search pill on the right.
struct TopBar: View {
    let model: AppModel
    let router: CommandRouter
    /// Room left for the floating window buttons.
    var trafficLightsWidth: CGFloat = 76

    var body: some View {
        ZStack {
            // Empty space drags the window; a double-click zooms it.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded { NSApp.keyWindow?.performZoom(nil) })

            if model.screen == .settings {
                HStack {
                    Spacer()
                    CircleButton(symbol: "xmark", size: 32, label: "Close Settings (Esc)") { model.show(.workspaces) }
                }
            } else {
                HStack(spacing: 8) {
                    Color.clear.frame(width: trafficLightsWidth, height: 1)
                    HomeMarkButton(active: model.screen == .home) { model.toggleHome() }
                    CircleButton(symbol: "sidebar.left", size: 32, label: "Toggle Sidebar (⌘B)") {
                        router.perform(.toggleSidebar)
                    }
                    Spacer()
                    SearchPill { router.perform(.commandPalette) }
                }
                SegmentedPill(
                    items: [(AppScreen.workspaces, "Workspaces"), (AppScreen.fleet, "Fleet")],
                    selection: Binding(
                        get: { model.screen == .fleet ? .fleet : .workspaces },
                        set: { model.show($0) }
                    ),
                    height: 34
                )
                .opacity(model.screen == .home ? 0.0 : 1)
                .allowsHitTesting(model.screen != .home)
            }
        }
        .padding(.horizontal, Sky.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Home circle carries the Arch M mark instead of a house glyph.
struct HomeMarkButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MothershipMark(variant: .mono(active ? Sky.onSelection : Sky.ink.opacity(0.85)), size: 22)
                .frame(width: 32, height: 32)
                .background {
                    if active {
                        Circle().fill(Sky.selection).overlay(Circle().strokeBorder(Sky.selectionStroke, lineWidth: 1))
                    } else {
                        Circle().fill(Color.clear).glass(Circle())
                            .overlay(Circle().fill(Sky.ink.opacity(hovering ? 0.05 : 0)))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Sky.hover) { self.hovering = hovering } }
        .help("Home (⌘0)")
        .accessibilityLabel("Home")
    }
}

/// "⌕ Search ⌘P" as a frosted capsule.
struct SearchPill: View {
    /// Fixed, so the toast dock can sit right beside it.
    static let width: CGFloat = 120
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Text("Search")
                    .font(Sky.Font.label)
                Text("⌘P")
                    .font(Sky.Font.meta)
                    .foregroundStyle(Sky.tertiary)
            }
            .foregroundStyle(Sky.secondary)
            .frame(width: Self.width, height: 32)
            .glassCapsule()
            .overlay(Capsule().fill(Sky.ink.opacity(hovering ? 0.04 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Sky.hover) { self.hovering = hovering } }
        .accessibilityLabel("Search")
    }
}
