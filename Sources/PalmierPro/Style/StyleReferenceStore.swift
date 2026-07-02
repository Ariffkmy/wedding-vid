import AVFoundation
import Foundation

/// Style reference library: global references (the editor's identity, every project)
/// live in Application Support; per-project references are media assets flagged
/// `isStyleReference` whose profiles cache by file identity. Analysis runs on a
/// serial background queue, one reference at a time.
@MainActor
@Observable
final class StyleReferenceStore {
    static let shared = StyleReferenceStore()

    struct GlobalReference: Codable, Identifiable, Sendable {
        var id: String
        var name: String
        var fileName: String
        var addedAt: Date
    }

    enum AnalysisState: Equatable {
        case pending
        case analyzing
        case done
        case failed(String)
    }

    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/style-references", isDirectory: true)
    static let profilesDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/style-profiles", isDirectory: true)

    private(set) var globalReferences: [GlobalReference] = []
    /// Analysis state keyed by global reference id or asset profile key.
    private(set) var states: [String: AnalysisState] = [:]

    private var queue: [(key: String, url: URL, profileURL: URL)] = []
    private var worker: Task<Void, Never>?

    private init() {
        loadIndex()
    }

    // MARK: - Global library

    private var indexURL: URL { Self.directory.appendingPathComponent("index.json") }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let refs = try? JSONDecoder().decode([GlobalReference].self, from: data) else { return }
        globalReferences = refs
        for ref in refs {
            states[ref.id] = FileManager.default.fileExists(atPath: profileURL(globalId: ref.id).path) ? .done : .pending
        }
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(globalReferences) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func videoURL(globalId: String) -> URL? {
        guard let ref = globalReferences.first(where: { $0.id == globalId }) else { return nil }
        return Self.directory.appendingPathComponent("\(ref.id)/\(ref.fileName)")
    }

    private func profileURL(globalId: String) -> URL {
        Self.directory.appendingPathComponent("\(globalId)/profile.json")
    }

    /// Copies the video into the library and queues analysis.
    @discardableResult
    func addGlobal(url: URL) throws -> GlobalReference {
        let id = UUID().uuidString
        let dir = Self.directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("video." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
        try FileManager.default.copyItem(at: url, to: dest)
        let ref = GlobalReference(
            id: id, name: url.deletingPathExtension().lastPathComponent,
            fileName: dest.lastPathComponent, addedAt: Date()
        )
        globalReferences.append(ref)
        saveIndex()
        enqueue(key: id, url: dest, profileURL: profileURL(globalId: id))
        return ref
    }

    func removeGlobal(id: String) {
        globalReferences.removeAll { $0.id == id }
        states[id] = nil
        queue.removeAll { $0.key == id }
        saveIndex()
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(id, isDirectory: true))
    }

    func globalProfile(id: String) -> StyleProfile? {
        loadProfile(at: profileURL(globalId: id))
    }

    // MARK: - Per-project references (flagged media assets)

    /// Profile cache key by file identity, so it survives project moves.
    nonisolated static func assetProfileKey(url: URL) -> String? {
        EmbeddingStore.key(for: url)
    }

    func assetProfile(url: URL) -> StyleProfile? {
        guard let key = Self.assetProfileKey(url: url) else { return nil }
        return loadProfile(at: Self.profilesDirectory.appendingPathComponent("\(key).json"))
    }

    /// Queues analysis for a flagged project asset if its profile is missing.
    func analyzeAssetIfNeeded(url: URL) {
        guard let key = Self.assetProfileKey(url: url) else { return }
        let dest = Self.profilesDirectory.appendingPathComponent("\(key).json")
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            states[key] = .done
            return
        }
        enqueue(key: key, url: url, profileURL: dest)
    }

    func assetAnalysisState(url: URL) -> AnalysisState? {
        Self.assetProfileKey(url: url).flatMap { states[$0] }
    }

    /// Queues any reference (global or flagged asset) still missing a profile.
    func sweep(editor: EditorViewModel?) {
        for ref in globalReferences where states[ref.id] != .done && states[ref.id] != .analyzing {
            if let url = videoURL(globalId: ref.id) {
                enqueue(key: ref.id, url: url, profileURL: profileURL(globalId: ref.id))
            }
        }
        if let editor {
            for asset in editor.mediaAssets where asset.isStyleReference && asset.type == .video {
                analyzeAssetIfNeeded(url: asset.url)
            }
        }
    }

    // MARK: - Analysis queue

    private func enqueue(key: String, url: URL, profileURL: URL) {
        guard states[key] != .analyzing, !queue.contains(where: { $0.key == key }) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            states[key] = .failed("File not found")
            return
        }
        states[key] = .pending
        queue.append((key, url, profileURL))
        ensureWorker()
    }

    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled {
                guard !self.queue.isEmpty else { break }
                let job = self.queue.removeFirst()
                self.states[job.key] = .analyzing
                do {
                    try await ExportCoordinator.waitWhileExportActive()
                    let profile = try await StyleAnalyzer.analyze(url: job.url)
                    try FileManager.default.createDirectory(
                        at: job.profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(profile).write(to: job.profileURL, options: .atomic)
                    self.states[job.key] = .done
                    Log.agent.notice("style profile ready key=\(job.key.prefix(8)) shots=\(profile.shots?.count ?? 0)")
                } catch is CancellationError {
                    self.states[job.key] = .pending
                } catch {
                    self.states[job.key] = .failed(error.localizedDescription)
                    Log.agent.warning("style analysis failed key=\(job.key.prefix(8)): \(error.localizedDescription)")
                }
            }
            self?.worker = nil
        }
    }

    /// Writes agent-authored vibe notes into an existing profile. False when the
    /// profile hasn't been analyzed yet.
    func updateVibeNotes(profileAt url: URL, notes: String) -> Bool {
        guard var profile = loadProfile(at: url) else { return false }
        profile.vibeNotes = notes
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(profile) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    func globalProfileURL(id: String) -> URL { profileURL(globalId: id) }

    func assetProfileURL(url: URL) -> URL? {
        Self.assetProfileKey(url: url).map { Self.profilesDirectory.appendingPathComponent("\($0).json") }
    }

    private func loadProfile(at url: URL) -> StyleProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StyleProfile.self, from: data)
    }
}

// MARK: - Merged guidance

/// The style the agent should follow, merged per aspect: project references win,
/// global references fill gaps, the bundled domain pack is the last fallback.
struct StyleGuidance: Sendable {
    struct MomentFraction: Sendable { var moment: String; var fraction: Double }

    var color: ColorSignature?
    var colorSource: String?

    var cutStats: StyleProfile.CutStats?
    var bpm: Double?
    var cutsOnBeatFraction: Double?
    var tempoSource: String?

    /// Single-reference structure: the exact edit order.
    var momentSequence: [String]?
    /// Multi-reference structure: pooled stats (same shape as the pack's learnedSequences).
    var openingMoments: [MomentFraction]?
    var commonNext: [String: [MomentFraction]]?
    var structureSource: String?   // "project" | "global" | "bundled"

    var vibeNotes: [String]

    static func merged(
        project: [StyleProfile], global: [StyleProfile], hasBundledPack: Bool,
        bundledColor: ColorSignature? = nil
    ) -> StyleGuidance {
        var g = StyleGuidance(vibeNotes: [])

        // Color: always present in a profile, so first non-empty tier wins; the
        // dataset-learned grade is the last fallback.
        for (tier, profiles) in [("project", project), ("global", global)] where g.color == nil {
            if let avg = ColorSignature.average(profiles.map(\.color)) {
                g.color = avg
                g.colorSource = tier
            }
        }
        if g.color == nil, let bundledColor {
            g.color = bundledColor
            g.colorSource = "bundled"
        }

        // Tempo: needs music or cut stats.
        for (tier, profiles) in [("project", project), ("global", global)] where g.tempoSource == nil {
            let withTempo = profiles.filter { $0.music != nil || $0.cutStats != nil }
            guard !withTempo.isEmpty else { continue }
            let bpms = withTempo.compactMap { $0.music?.bpm }.sorted()
            if !bpms.isEmpty { g.bpm = bpms[bpms.count / 2] }
            let beatFracs = withTempo.compactMap(\.cutsOnBeatFraction)
            if !beatFracs.isEmpty { g.cutsOnBeatFraction = beatFracs.reduce(0, +) / Double(beatFracs.count) }
            g.cutStats = pooledCutStats(withTempo.compactMap(\.cutStats))
            g.tempoSource = tier
        }

        // Structure: moment sequences.
        for (tier, profiles) in [("project", project), ("global", global)] where g.structureSource == nil {
            let seqs = profiles.compactMap(\.momentSequence).filter { !$0.isEmpty }
            guard !seqs.isEmpty else { continue }
            if seqs.count == 1 {
                g.momentSequence = seqs[0]
            } else {
                let pooled = pooledSequences(seqs)
                g.openingMoments = pooled.opening
                g.commonNext = pooled.commonNext
            }
            g.structureSource = tier
        }
        if g.structureSource == nil, hasBundledPack {
            g.structureSource = "bundled"
        }

        g.vibeNotes = (project + global).compactMap(\.vibeNotes).filter { !$0.isEmpty }
        return g
    }

    static func pooledCutStats(_ stats: [StyleProfile.CutStats]) -> StyleProfile.CutStats? {
        guard !stats.isEmpty else { return nil }
        func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
        return StyleProfile.CutStats(
            shotCount: stats.map(\.shotCount).reduce(0, +),
            medianShotSec: median(stats.map(\.medianShotSec)),
            p25ShotSec: median(stats.map(\.p25ShotSec)),
            p75ShotSec: median(stats.map(\.p75ShotSec)),
            shotsPerMinute: median(stats.map(\.shotsPerMinute))
        )
    }

    /// Opening-moment and next-moment transition fractions pooled across sequences —
    /// the same shape the bundled pack's learnedSequences uses.
    static func pooledSequences(
        _ seqs: [[String]]
    ) -> (opening: [MomentFraction], commonNext: [String: [MomentFraction]]) {
        var openings: [String: Int] = [:]
        var transitions: [String: [String: Int]] = [:]
        for seq in seqs {
            if let first = seq.first { openings[first, default: 0] += 1 }
            for (a, b) in zip(seq, seq.dropFirst()) where a != b {
                transitions[a, default: [:]][b, default: 0] += 1
            }
        }
        func fractions(_ counts: [String: Int], topK: Int = 3) -> [MomentFraction] {
            let total = Double(counts.values.reduce(0, +))
            guard total > 0 else { return [] }
            return counts.sorted { $0.value > $1.value }.prefix(topK).map {
                MomentFraction(moment: $0.key, fraction: (Double($0.value) / total * 100).rounded() / 100)
            }
        }
        return (fractions(openings), transitions.mapValues { fractions($0) })
    }
}
