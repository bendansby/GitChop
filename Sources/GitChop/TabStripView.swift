import SwiftUI

/// Horizontal strip of open-repo tabs with a trailing "+" button.
/// Visual style mirrors modern Finder / Safari window tabs: a tab bar
/// with a subtle baseline divider, tab pills inset with consistent
/// breathing room top and bottom, distinct selected state.
struct TabStripView: View {
    @EnvironmentObject var workspace: Workspace

    /// Bar height. Tab pill is inset from this by `tabVerticalInset`
    /// on each edge so the pill never visually clips the divider rules.
    private let barHeight: CGFloat = 42
    private let tabVerticalInset: CGFloat = 7

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.sessions) { session in
                        TabView(
                            session: session,
                            verticalInset: tabVerticalInset
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider()
                .frame(height: barHeight - 12)

            Button {
                workspace.openPicker()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: barHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open another repo (⌘O)")
        }
        .frame(height: barHeight)
        .background(Color(.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// One tab in the strip. The whole pill is the activation target;
/// the close X is overlaid on the trailing edge with reserved width
/// so tabs don't shift when it shows on hover.
private struct TabView: View {
    @ObservedObject var session: RebaseSession
    @EnvironmentObject var workspace: Workspace
    @State private var hovering = false
    let verticalInset: CGFloat

    var body: some View {
        let isActive = workspace.activeSessionID == session.id

        Button {
            workspace.setActive(session.id)
        } label: {
            HStack(spacing: 6) {
                Text(session.repoName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if !session.branch.isEmpty {
                    Text(session.branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                // Reserved width for the close X so tabs don't reflow
                // when hover reveals it.
                Color.clear.frame(width: 16, height: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(tabBackground(isActive: isActive))
            .overlay(tabBorder(isActive: isActive))
        }
        .buttonStyle(.plain)
        .padding(.vertical, verticalInset)   // breathing room from the bar's top/bottom rules
        .overlay(alignment: .trailing) {
            if isActive || hovering {
                Button {
                    workspace.requestClose(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle().fill(Color.secondary.opacity(hovering ? 0.18 : 0))
                        )
                }
                .buttonStyle(.plain)
                .help("Close tab")
                .padding(.trailing, 9)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Layered fill:  selected uses the controlBackgroundColor (the
    /// material macOS uses for a "lifted" surface like a popover or
    /// inset selection), hover bumps the inactive fill very slightly,
    /// inactive is fully transparent.
    @ViewBuilder
    private func tabBackground(isActive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if isActive {
            shape.fill(Color(.controlBackgroundColor))
        } else if hovering {
            shape.fill(Color.primary.opacity(0.05))
        } else {
            shape.fill(.clear)
        }
    }

    /// Hairline border on the active tab so the lifted-surface effect
    /// reads cleanly against the bar background. Inactive tabs have
    /// no border.
    @ViewBuilder
    private func tabBorder(isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}
