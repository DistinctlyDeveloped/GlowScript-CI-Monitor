import Foundation

actor LocalCIService {
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Octowatch/ci-status.json")

    func read() throws -> CIHostSnapshot {
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(CIHostSnapshot.self, from: data)
    }
}
