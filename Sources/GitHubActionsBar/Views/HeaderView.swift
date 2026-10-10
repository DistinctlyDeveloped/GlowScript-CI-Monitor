import SwiftUI

struct HeaderView: View {
    let onRefresh: () -> Void
    let onSettings: () -> Void
    var onOpenTracker: (() -> Void)? = nil
    var isLoading: Bool

    var body: some View {
        HStack {
            Text("GlowScript CI Monitor")
                .font(.headline)

            Spacer()

            if let onOpenTracker {
                Button(action: onOpenTracker) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help("Open project tracker window")
            }

            Button(action: onRefresh) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
