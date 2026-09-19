import SwiftUI

@main
struct GitHubActionsBarApp: App {
    @State private var viewModel = WorkflowViewModel()

    var body: some Scene {
        MenuBarExtra {
            MainPopoverView(viewModel: viewModel)
                .frame(width: min(920, (NSScreen.main?.visibleFrame.width ?? 1000) - 40),
                       height: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 60))
        } label: {
            MenuBarLabel(repoStatuses: viewModel.repoStatuses, pulsePhase: viewModel.pulsePhase)
        }
        .menuBarExtraStyle(.window)
    }
}
