import SwiftUI

struct MainPopoverView: View {
    @Bindable var viewModel: WorkflowViewModel
    var showsTrackerButton = false
    /// Inside the tracker window the view is a plain pane: no material backing, no
    /// panel corner masking (which would otherwise reshape the host window), and no
    /// header of its own because the window toolbar carries title, refresh, and settings.
    var embedded = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !viewModel.isAuthenticated {
                SignInView(viewModel: viewModel)
            } else if viewModel.showSettings {
                SettingsView(viewModel: viewModel, showsHeader: !embedded) {
                    viewModel.showSettings = false
                    viewModel.refresh()
                }
            } else {
                authenticatedContent
            }
        }
        .background(embedded ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
        .panelCorners(enabled: !embedded)
    }

    private var authenticatedContent: some View {
        VStack(spacing: 0) {
            if !embedded {
                HeaderView(
                    onRefresh: { viewModel.refresh() },
                    onSettings: { viewModel.showSettings = true },
                    onOpenTracker: showsTrackerButton ? {
                        openWindow(id: "project-tracker")
                        NSApp.activate(ignoringOtherApps: true)
                    } : nil,
                    isLoading: viewModel.isLoading
                )

                Divider()
            }

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            CIDashboardView(viewModel: viewModel)

            Divider()

            FooterView(
                username: viewModel.username,
                onSignOut: { viewModel.signOut() }
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.1))
    }
}
