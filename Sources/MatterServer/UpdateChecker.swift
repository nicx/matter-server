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
    @Published private(set) var isUpdating = false

    private let settings: AppSettings
    private let log: LogStore
    private let server: ServerController
    private var timer: Timer?
    private let lastNotifiedKey = "update.lastNotifiedVersion"

    init(settings: AppSettings, log: LogStore, server: ServerController) {
        self.settings = settings
        self.log = log
        self.server = server
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

                Release notes: \(UpdateChecker.releaseNotesURL(for: latest))

                Open MatterServer → Settings → Updates and click “Update matter-server”.
                """,
                config: settings.mailConfig
            )
            UserDefaults.standard.set(latest, forKey: lastNotifiedKey)
            log.appendSystem("Update \(latest) available — email sent to \(settings.updateEmailRecipient)")
            postLocalNotification(title: "matter-server \(latest) available", body: "Notification email sent.")
        } catch {
            lastError = "Email failed: \(error.localizedDescription)"
            log.appendSystem("Update-notification email failed: \(error.localizedDescription)")
        }
    }

    // MARK: - In-app update

    /// Update the bundled `matter-server` to the latest npm release, in place,
    /// then restart the server. Uses the Node + npm shipped in the (signed)
    /// bundle to install into the writable copy outside the bundle, so the app's
    /// code signature stays intact. Mirrors the sibling apps' update buttons.
    func updateMatterServer() async {
        guard !isUpdating else { return }
        isUpdating = true
        lastError = nil
        defer { isUpdating = false }

        // Make sure the writable copy exists (seed from the bundle if needed).
        BundledRuntime.ensureServerSeeded()
        let node = BundledRuntime.nodeExecutableURL
        let npm = BundledRuntime.npmCliURL
        let dest = BundledRuntime.serverDirectory

        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: npm.path) else {
            lastError = "Bundled npm not found — rebuild the app (Scripts/bundle-runtime.sh now keeps npm)."
            log.appendSystem("Update failed: bundled npm missing at \(npm.path)")
            return
        }

        let target = latestVersion.map { "matter-server@\($0)" } ?? "matter-server@latest"
        let before = BundledRuntime.installedServerVersion ?? "unknown"
        log.appendSystem("Updating matter-server (\(before) → \(target)) via bundled npm…")

        let ok = await runNpm(node: node, npm: npm,
                              args: ["install", target, "--omit=dev",
                                     "--prefix", dest.path, "--no-audit", "--no-fund"])
        guard ok else {
            lastError = "matter-server update failed — see the log window."
            log.appendSystem("matter-server update failed")
            return
        }

        let after = BundledRuntime.installedServerVersion ?? "unknown"
        log.appendSystem("matter-server updated to \(after) — restarting server")
        server.restart()
        // Refresh the "latest" comparison so the UI reflects the new state.
        await check(notifyByEmail: false)
    }

    /// Run the bundled `node npm-cli.js …`, streaming output to the log window.
    /// Returns true on exit code 0.
    private func runNpm(node: URL, npm: URL, args: [String]) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = node
            proc.arguments = [npm.path] + args
            var env = ProcessInfo.processInfo.environment
            let nodeBin = node.deletingLastPathComponent().path
            env["PATH"] = nodeBin + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            proc.environment = env

            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            let stream: @Sendable (FileHandle) -> Void = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                guard let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.log.append(text) }
            }
            outPipe.fileHandleForReading.readabilityHandler = stream
            errPipe.fileHandleForReading.readabilityHandler = stream

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus == 0)
            }
            do {
                try FileManager.default.createDirectory(at: BundledRuntime.serverDirectory,
                                                        withIntermediateDirectories: true)
                try proc.run()
            } catch {
                Task { @MainActor [weak self] in
                    self?.log.appendSystem("npm launch failed: \(error.localizedDescription)")
                }
                cont.resume(returning: false)
            }
        }
    }

    /// Send a test email so the user can verify the relay configuration.
    func sendTestEmail() async {
        lastError = nil
        do {
            try await Mailer.send(
                subject: "MatterServer test email",
                body: "This is a test email from MatterServer, sent via your local mail relay. If you received it, update notifications will work.",
                config: settings.mailConfig
            )
            log.appendSystem("Test email sent to \(settings.updateEmailRecipient)")
            postLocalNotification(title: "Test email sent", body: settings.updateEmailRecipient)
        } catch {
            lastError = "Email failed: \(error.localizedDescription)"
            log.appendSystem("Test email failed: \(error.localizedDescription)")
        }
    }

    private func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// GitHub release-notes page for a given matter-server version. Tags follow
    /// the `v<version>` convention (e.g. v1.1.4); the page is the per-version
    /// changelog upstream publishes for each release.
    static func releaseNotesURL(for version: String) -> String {
        "https://github.com/matter-js/matterjs-server/releases/tag/v\(version)"
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
