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
    /// Cooldown floor and ceiling. A restart that turns out not to have
    /// helped doubles the wait before the next attempt (see
    /// `ineffectiveRestartStreak`); a restart that clearly helped resets it
    /// back to the floor.
    private let baseCooldown: TimeInterval = 60 * 60
    private let maxCooldown: TimeInterval = 24 * 60 * 60

    private var degradedSince: Date?
    private var lastActionAt: Date?
    /// The unavailable node set at the moment of the *last* restart, so the
    /// next trigger can tell whether that restart actually helped.
    private var lastActionUnavailableNodeIDs: Set<Int> = []
    /// Consecutive restarts that left essentially the same nodes unavailable
    /// — i.e. devices that are genuinely detached from the Thread mesh (need
    /// a battery pull) rather than matter-server sitting on a stale address.
    /// Restarting again can never fix that on its own; without this, the
    /// watchdog would restart the whole fleet every `baseCooldown` forever,
    /// bothering the other, healthy devices for nothing (seen live overnight
    /// 2026-08-22→23: 10 restarts, hourly, same ~13 stuck sensors each time).
    private var ineffectiveRestartStreak = 0

    private var currentCooldown: TimeInterval {
        min(baseCooldown * pow(2, Double(ineffectiveRestartStreak)), maxCooldown)
    }

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
        guard let snapshot = await queryAvailability() else { return }
        lastCheck = (snapshot.unavailable, snapshot.total)

        guard snapshot.unavailable >= settings.watchdogUnavailableThreshold else {
            degradedSince = nil
            // Fully recovered — don't let a stale backoff from an unrelated
            // past incident slow down the response to a future one.
            ineffectiveRestartStreak = 0
            return
        }

        if degradedSince == nil {
            degradedSince = Date()
            log.appendSystem("Watchdog: \(snapshot.unavailable)/\(snapshot.total) nodes unavailable — watching")
        }
        guard let since = degradedSince else { return }
        let sustained = Date().timeIntervalSince(since)
        guard sustained >= TimeInterval(settings.watchdogSustainedMinutes * 60) else { return }

        if let lastActionAt, Date().timeIntervalSince(lastActionAt) < currentCooldown {
            return // already logged the degraded state above; stay quiet during cooldown
        }

        // Judge the *previous* restart before committing to this one: if
        // most of the same nodes are still down, it didn't help — back off
        // further next time instead of retrying at the same pace forever.
        let currentIDs = Set(snapshot.unavailableNodeIDs)
        if lastActionAt != nil, !lastActionUnavailableNodeIDs.isEmpty {
            let overlap = Double(currentIDs.intersection(lastActionUnavailableNodeIDs).count)
                / Double(lastActionUnavailableNodeIDs.count)
            if overlap >= 0.7 {
                ineffectiveRestartStreak += 1
                log.appendSystem("Watchdog: last restart didn't help (\(Int(overlap * 100))% of the same devices still unavailable) — these are likely detached from the Thread mesh and need a battery pull, not a restart. Backing off to \(Int(currentCooldown / 3600))h between attempts.")
            } else {
                ineffectiveRestartStreak = 0
            }
        }

        lastActionAt = Date()
        lastActionUnavailableNodeIDs = currentIDs
        degradedSince = nil
        let sustainedMinutes = Int(sustained / 60)
        log.appendSystem("Watchdog: \(snapshot.unavailable)/\(snapshot.total) nodes unavailable for \(sustainedMinutes) min — restarting the server")
        server.restart()
        await notifyRestart(snapshot: snapshot, sustainedMinutes: sustainedMinutes, ineffectiveStreak: ineffectiveRestartStreak)
    }

    /// Email the trigger data for a watchdog-initiated restart, if the user
    /// opted in and configured a recipient. Best-effort: a failed send is
    /// logged, not retried — the restart itself already happened.
    private func notifyRestart(snapshot: AvailabilitySnapshot, sustainedMinutes: Int, ineffectiveStreak: Int) async {
        guard settings.watchdogRestartEmailEnabled, !settings.updateEmailRecipient.isEmpty else { return }
        let names = HomeAssistantDeviceNames.lookup()
        let deviceList = snapshot.unavailableNodeIDs.sorted()
            .map { id in names[id].map { "\($0) (#\(id))" } ?? "#\(id)" }
            .joined(separator: "\n")
        let streakNote = ineffectiveStreak == 0 ? "" : """


        Note: the previous restart(s) did not bring these devices back — \(ineffectiveStreak) in a row now. \
        That points to devices genuinely detached from the Thread mesh rather than a server-side stall; \
        a battery pull is likely needed. The watchdog is backing off to \(Int(currentCooldown / 3600))h \
        between attempts so it stops bothering the rest of the fleet for this.
        """
        do {
            try await Mailer.send(
                subject: "MatterServer: watchdog restarted the server",
                body: """
                The availability watchdog restarted matter-server because too many devices stayed unreachable.

                Unavailable: \(snapshot.unavailable) of \(snapshot.total) devices
                Sustained for: \(sustainedMinutes) min (threshold: \(settings.watchdogUnavailableThreshold) devices for \(settings.watchdogSustainedMinutes) min)
                Triggered at: \(Self.timestampFormatter.string(from: Date()))

                Unavailable devices:
                \(deviceList.isEmpty ? "—" : deviceList)\(streakNote)

                Open MatterServer → Show Logs for the full picture.
                """,
                config: settings.mailConfig)
            log.appendSystem("Watchdog restart alert emailed to \(settings.updateEmailRecipient)")
        } catch {
            log.appendSystem("Watchdog restart alert email failed: \(error.localizedDescription)")
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private struct AvailabilitySnapshot {
        let unavailable: Int
        let total: Int
        let unavailableNodeIDs: [Int]
    }

    /// One-shot `get_nodes` round trip over the server's own WebSocket API,
    /// matched by `message_id` so it doesn't care what the server pushes
    /// first (a `server_info` handshake on connect, in current versions).
    private func queryAvailability() async -> AvailabilitySnapshot? {
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
            let unavailableIDs = nodes.compactMap { node -> Int? in
                guard (node["available"] as? Bool) == false else { return nil }
                return node["node_id"] as? Int
            }
            return AvailabilitySnapshot(unavailable: unavailableIDs.count, total: nodes.count,
                                         unavailableNodeIDs: unavailableIDs)
        }
    }
}
