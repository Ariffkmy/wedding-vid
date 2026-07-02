import Foundation

/// Color grading learned from the reference dataset by scripts/build_color_profile.py.
/// `overall` is the bundled color fallback when the user has no style references;
/// `looks` are the dataset's distinct grading styles.
struct DomainColorProfile: Decodable, Sendable {
    let domain: String
    let videosAnalyzed: Int
    let overall: ColorSignature
    let looks: [Look]

    struct Look: Decodable, Sendable {
        let id: String
        let name: String
        let videoCount: Int
        let lutFile: String?
        let signature: ColorSignature
    }

    func look(_ id: String) -> Look? {
        looks.first { $0.id == id || $0.name == id }
    }
}

enum DomainColorStore {
    @MainActor private static var cache: [String: DomainColorProfile?] = [:]

    @MainActor
    static func load(_ domain: String) -> DomainColorProfile? {
        if let hit = cache[domain] { return hit }
        let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let devRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
        let name = "DomainPacks/\(domain)_colors.json"
        let candidates = [
            root.appendingPathComponent(name),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(name)"),
            devRoot.appendingPathComponent("Sources/PalmierPro/Resources/\(name)"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let profile = try? JSONDecoder().decode(DomainColorProfile.self, from: data) {
                cache[domain] = profile
                return profile
            }
        }
        cache[domain] = DomainColorProfile?.none
        return nil
    }

    /// Absolute path of a look's bundled .cube LUT, or nil if absent.
    @MainActor
    static func lutURL(fileName: String) -> URL? {
        let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let devRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
        let name = "DomainPacks/LUTs/\(fileName)"
        let candidates = [
            root.appendingPathComponent(name),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/\(name)"),
            devRoot.appendingPathComponent("Sources/PalmierPro/Resources/\(name)"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
