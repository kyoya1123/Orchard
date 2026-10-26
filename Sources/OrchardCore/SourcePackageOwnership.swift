import Foundation

/// Written under the package lease. Legacy caches without a receipt are retained.
struct SourcePackageOwnership: Codable, Sendable {
    let owner: ArtifactOwner
    let repositoryCacheID: String
    let resolved: Data

    func validateLayout(_ packages: URL) throws {
        let allowed: Set<String> = ["checkouts", "repositories", "artifacts", "workspace-state.json"]
        let entries = try FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard Set(entries.map(\.lastPathComponent)).isSubset(of: allowed),
              try entries.allSatisfy({ try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true }) else {
            throw OrchardError.message("Unknown files or links in package cache")
        }
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: packages.appendingPathComponent("workspace-state.json"))) as? [String: Any]
        guard let object = state?["object"] as? [String: Any],
              let dependencies = object["dependencies"] as? [[String: Any]] else {
            throw OrchardError.message("Unknown package state")
        }
        let expected = Set(dependencies.compactMap { $0["subpath"] as? String })
        let actual = Set(try FileManager.default.contentsOfDirectory(atPath: packages.appendingPathComponent("checkouts").path))
        guard expected.count == dependencies.count, expected == actual else {
            throw OrchardError.message("Extra or missing package checkouts")
        }
    }
}
