import Foundation

/// Watches the server's own view of device availability and auto-restarts it
/// when a large share of nodes has stayed `unavailable` for a while.
///
/// This guards against matter-server itself, not the Thread network: after
/// the mesh reforms (an ATV/HomePod restart, a power outage, or even this
/// app's own restart can each mint a new OMR prefix), matter-server can get
/// stuck retrying stale cached IPv6 addresses for a node and never re-resolve
/// it. Confirmed live on 2026-08-22: dozens of nodes stayed `unavailable` for
/// hours with the Thread network itself completely calm, while `dns-sd`
/// resolved their current, pingable addresses just fine — matter-server had
/// simply stopped asking. A plain restart reliably unstuck it every time that
/// day; this automates that same manual fix.
@MainActor
final class AvailabilityWatchdog: ObservableObject {
    /// Most recent successful poll, for a small status line in Settings.
    @Published private(set) var lastCheck: (unavailable: Int, total: Int)?

    private let settings: AppSettings
    private let log: LogStore
    private let server: ServerController
    private var timer: Timer?

    private let pollInterval: TimeInterval = 60
    /// After a start, matter-server is still resubscribing to every node —
    /// most of them briefly show `unavailable` as a matter of course. Give it
    /// this long before treating a high count as a stall rather than normal
    /// startup churn.
    private let startupGrace: TimeInterval = 5 * 60
    /// Once we act, stay quiet for this long even if still degraded, so a
    /// genuinely unstable Thread mesh (not a stale-address stall) doesn't get
    /// restarted in a tight loop.
    private let cooldown: TimeInterval = 60 * 60

    private var degradedSince: Date?
    private var lastActionAt: Date?

    init(settings: AppSettings, log: LogStore, server: ServerController) {
        self.settings = settings
        self.log = log
        self.server = server
    }

    func startScheduling() {
        timer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopScheduling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() async {
        guard settings.watchdogEnabled else { degradedSince = nil; return }
        guard server.status == .running, let startedAt = server.startedAt,
              Date().timeIntervalSince(startedAt) > startupGrace else {
            degradedSince = nil
            return
        }

        // A failed query (server briefly unreachable, still booting its
        // WebSocket) tells us nothing — leave the degraded streak as-is
        // rather than resetting or acting on it.
        guard let (unavailable, total) = await queryAvailability() else { return }
        lastCheck = (unavailable, total)

        guard unavailable >= settings.watchdogUnavailableThreshold else {
            degradedSince = nil
            return
        }

        if degradedSince == nil {
            degradedSince = Date()
            log.appendSystem("Watchdog: \(unavailable)/\(total) nodes unavailable — watching")
        }
        guard let since = degradedSince,
              Date().timeIntervalSince(since) >= TimeInterval(settings.watchdogSustainedMinutes * 60) else { return }

        if let lastActionAt, Date().timeIntervalSince(lastActionAt) < cooldown {
            return // already logged the degraded state above; stay quiet during cooldown
        }

        lastActionAt = Date()
        degradedSince = nil
        log.appendSystem("Watchdog: \(unavailable)/\(total) nodes unavailable for over \(settings.watchdogSustainedMinutes) min — restarting the server")
        server.restart()
    }

    /// One-shot `get_nodes` round trip over the server's own WebSocket API,
    /// matched by `message_id` so it doesn't care what the server pushes
    /// first (a `server_info` handshake on connect, in current versions).
    private func queryAvailability() async -> (unavailable: Int, total: Int)? {
        guard let url = URL(string: "ws://127.0.0.1:\(settings.port)/ws") else { return nil }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let payload: [String: Any] = ["message_id": "watchdog", "command": "get_nodes"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8),
              (try? await task.send(.string(text))) != nil else { return nil }

        // Cancelling on timeout makes any in-flight `receive()` throw, which
        // the loop below treats as failure — URLSessionWebSocketTask has no
        // receive-with-timeout of its own.
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { timeoutTask.cancel() }

        while true {
            guard let message = try? await task.receive() else { return nil }
            guard case .string(let json) = message,
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  obj["message_id"] as? String == "watchdog" else { continue }
            guard let nodes = obj["result"] as? [[String: Any]] else { return nil }
            let unavailable = nodes.filter { ($0["available"] as? Bool) == false }.count
            return (unavailable, nodes.count)
        }
    }
}
