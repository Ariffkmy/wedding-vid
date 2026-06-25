import Foundation

/// Lock-protected cache for stabilization analysis results,
/// safe to read from CI render closures (must be synchronous).
final class StabilizationCache: @unchecked Sendable {
    static let shared = StabilizationCache()

    private var storage: [String: StabilizationData] = [:]
    private let lock = NSLock()

    private func key(clip: Clip, sourceURL: URL) -> String {
        "\(sourceURL.path):\(clip.trimStartFrame)-\(clip.trimEndFrame)"
    }

    func get(clip: Clip, sourceURL: URL) -> StabilizationData? {
        lock.lock(); defer { lock.unlock() }
        return storage[key(clip: clip, sourceURL: sourceURL)]
    }

    func get(key: String) -> StabilizationData? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(clip: Clip, sourceURL: URL, data: StabilizationData) {
        lock.lock(); defer { lock.unlock() }
        storage[key(clip: clip, sourceURL: sourceURL)] = data
    }

    func set(key: String, data: StabilizationData) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
