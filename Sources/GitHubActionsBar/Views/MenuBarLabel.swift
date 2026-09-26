import SwiftUI

struct MenuBarLabel: View {
    let repoStatuses: [RepoStatusItem]
    let pulsePhase: Bool
    /// A local CI host or lane needs attention (collector alert). Shown even when every repo is green.
    var ciAlert: Bool = false

    var body: some View {
        if repoStatuses.isEmpty && !ciAlert {
            Image(systemName: "circle.dashed")
                .symbolRenderingMode(.hierarchical)
        } else {
            Image(nsImage: renderBubbles())
        }
    }

    @MainActor
    private func renderBubbles() -> NSImage {
        let content = HStack(spacing: 3) {
            ForEach(repoStatuses) { item in
                ZStack {
                    Circle()
                        .fill(item.status.bubbleColor)
                        .frame(width: 16, height: 16)

                    Text(String(item.initial))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .opacity(item.status == .inProgress ? (pulsePhase ? 1.0 : 0.4) : 1.0)
            }
            if ciAlert {
                ZStack {
                    Circle().fill(Color.red).frame(width: 16, height: 16)
                    Text("!").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                }
            }
        }

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0

        guard let cgImage = renderer.cgImage else {
            return NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: nil)
                ?? NSImage()
        }

        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: CGFloat(cgImage.width) / 2.0,
                height: CGFloat(cgImage.height) / 2.0
            )
        )
        nsImage.isTemplate = false
        return nsImage
    }
}

extension AggregateStatus {
    var bubbleColor: Color {
        switch self {
        case .idle: return .gray
        case .allGreen: return .green
        case .inProgress: return .orange
        case .failed: return .red
        case .mixed: return .red
        }
    }
}
