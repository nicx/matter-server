import Foundation
import UserNotifications

/// Periodically checks npm for a newer stable `matter-server` release and, when
/// one appears, emails the configured recipient (once per version) via the
/// local mail relay.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var latestVersion: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isChecking = false

    private let settings: AppSettings
    private let log: LogStore
    private var timer: Timer?
    private let lastNotifiedKey = "update.lastNotifiedVersion"

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    var installedVersion: String? { BundledRuntime.installedServerVersion }

    var updateAvailable: Bool {
        guard let latest = latestVersion, let installed = installedVersion else { return false }
        return UpdateChecker.isNewer(latest, than: installed)
    }

    // MARK: - Scheduling

    func startScheduling() {
        timer?.invalidate()
        // Daily check while the app runs (start-at-login keeps it alive).
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(notifyByEmail: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Catch-up check shortly after launch.
        Task { await check(notifyByEmail: true) }
    }

    // MARK: - Check

    @discardableResult
    func check(notifyByEmail: Bool) async -> String? {
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        guard let url = URL(string: "https://registry.npmjs.org/matter-server/latest") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String else {
                lastError = "Unexpected response from npm registry"
                return nil
            }
            latestVersion = version
            lastChecked = Date()
            if notifyByEmail { await notifyIfUpdate(latest: version) }
            return version
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func notifyIfUpdate(latest: String) async {
        guard let installed = installedVersion, UpdateChecker.isNewer(latest, than: installed) else { return }
        guard settings.updateEmailEnabled, !settings.updateEmailRecipient.isEmpty else { return }
        // Only email once per new version.
        guard UserDefaults.standard.string(forKey: lastNotifiedKey) != latest else { return }

        do {
            try await Mailer.send(
                subject: "matter-server update available: \(latest)",
                body: """
                A newer matter-server release is available.

                Installed: \(installed)
                Latest:    \(latest)

                To update, re-run Scripts/bundle-runtime.sh and rebuild MatterServer.app.
                """,
                config: mailConfig()
            )
            UserDefaults.standard.set(latest, forKey: lastNotifiedKey)
            log.appendSystem("Update \(latest) available — email sent to \(settings.updateEmailRecipient)")
            postLocalNotification(title: "matter-server \(latest) available", body: "Notification email sent.")
        } catch {
            lastError = "Email failed: \(error.localizedDescription)"
            log.appendSystem("Update-notification email failed: \(error.localizedDescription)")
        }
    }

    /// Send a test email so the user can verify the relay configuration.
    func sendTestEmail() async {
        lastError = nil
        do {
            try await Mailer.send(
                subject: "MatterServer test email",
                body: "This is a test email from MatterServer, sent via your local mail relay. If you received it, update notifications will work.",
                config: mailConfig()
            )
            log.appendSystem("Test email sent to \(settings.updateEmailRecipient)")
            postLocalNotification(title: "Test email sent", body: settings.updateEmailRecipient)
        } catch {
            lastError = "Email failed: \(error.localizedDescription)"
            log.appendSystem("Test email failed: \(error.localizedDescription)")
        }
    }

    private func mailConfig() -> Mailer.Config {
        Mailer.Config(
            host: settings.smtpHost,
            port: settings.smtpPort,
            sender: settings.updateEmailSender,
            recipient: settings.updateEmailRecipient
        )
    }

    private func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Compare two dotted numeric versions (stable semver). Pre-release/build
    /// suffixes are ignored; we only ever compare the stable `latest` tag.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map(String.init)?
                .split(separator: ".").map { Int($0) ?? 0 } ?? []
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
