import AppKit
import Network

/// Watches connectivity and warns the user when the AI/online features go dark.
/// Editing is local and keeps working; only network-backed features pause.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.kawenreel.network-monitor")
    private var started = false
    private var didWarnOffline = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: queue)
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online {
            didWarnOffline = false
        } else {
            warnOffline()
        }
    }

    private func warnOffline() {
        guard !didWarnOffline else { return }
        didWarnOffline = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No internet connection"
        alert.informativeText = """
        Kawenreel's AI features need an internet connection. You can keep editing \
        your project, but the AI assistant, media generation, and other online tools \
        are paused until you're back online.
        """
        alert.addButton(withTitle: "Continue Editing")
        alert.runModal()
    }
}
