import SwiftUI

/// Horizontal strip of open-repo tabs with a trailing "+" button.
/// Click to switch, hover-and-click the X to close, click "+" to open
/// another repo via the standard picker.
struct TabStripView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.sessions) { session in
                        TabView(session: session)
                    }
                }
                .padding(.horizontal, 4)
            }

            Divider()
                .frame(height: 22)

            Button {
                workspace.openPicker()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .help("Open another repo (⌘O)")
        }
        .frame(height: 36)
        .background(Color(.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// One tab in the strip. The whole pill is the activation target so
/// clicks on padding around the label still switch tabs; the close X
/// is overlaid as a small button on the trailing edge.
private struct TabView: View {
    @ObservedObject var session: RebaseSession
    @EnvironmentObject var workspace: Workspace
    @State private var hovering = false

    var body: some View {
        let isActive = workspace.activeSessionID == session.id

        // Whole-pill activate button. We reserve trailing space inside
        // the label for the close X so the overlaid button doesn't sit
        // on top of clickable text.
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
                // Reserved space for the close X. Same width whether
                // visible or not, so tabs don't shift on hover.
                Color.clear.frame(width: 16, height: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                          ? Color.primary.opacity(0.10)
                          : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            // Close button: rendered on top of the reserved-width
            // trailing area. Active tab's close is always shown;
            // inactive tabs reveal it on hover so the strip stays calm.
            if isActive || hovering {
                Button {
                    workspace.close(session.id)
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
                .padding(.trailing, 8)
            }
        }
        .onHover { hovering = $0 }
    }
}
