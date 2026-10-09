import SwiftUI

struct FooterView: View {
    let username: String
    let onSignOut: () -> Void

    var body: some View {
        HStack {
            Label(username, systemImage: "person.circle")
                .font(.caption)
                .foregroundStyle(.monitorSecondary)
                .lineLimit(1)

            Spacer()

            Button("Sign Out") {
                onSignOut()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.monitorSecondary)

            Text("·")
                .foregroundStyle(.quaternary)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.monitorSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
