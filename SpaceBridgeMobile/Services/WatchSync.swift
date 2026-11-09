import Foundation
import WatchConnectivity

/// Sends the storage summary to the paired Apple Watch (device-to-device, never via our servers).
final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private let lock = NSLock()
    private var pending: [String: Any]?

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ summary: WatchSummary) {
        guard let session else { return }
        let payload = summary.dictionary
        if session.activationState == .activated {
            push(payload, on: session)
        } else {
            lock.lock(); pending = payload; lock.unlock()
        }
    }

    private func push(_ payload: [String: Any], on session: WCSession) {
        guard session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(payload)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        lock.lock(); let payload = pending; pending = nil; lock.unlock()
        if let payload { push(payload, on: session) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for a newly paired watch.
        session.activate()
    }
}
