import SwiftUI
import UserNotifications

/// Owns the long-lived managers and wires up lifecycle (notifications, server
/// auto-start, backup scheduling, clean shutdown).
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let log: LogStore
    let server: ServerController
    let backup: BackupManager
    let loginItem: LoginItemManager
    let updateChecker: UpdateChecker

    init() {
        let settings = AppSettings.shared
        let log = LogStore()
        let server = ServerController(settings: settings, log: log)
        self.settings = settings
        self.log = log
        self.server = server
        self.backup = BackupManager(settings: settings, server: server, log: log)
        self.loginItem = LoginItemManager()
        self.updateChecker = UpdateChecker(settings: settings, log: log, server: server)
        wireOutageEmail()
    }

    /// Email the user when the server suffers a sustained outage (crash that
    /// can't recover). Gated on the opt-in toggle + a configured recipient.
    private func wireOutageEmail() {
        server.onOutage = { [weak self] reason in
            guard let self,
                  self.settings.serverDownEmailEnabled,
                  !self.settings.updateEmailRecipient.isEmpty else { return }
            let config = self.settings.mailConfig
            let recipient = self.settings.updateEmailRecipient
            Task { @MainActor in
                do {
                    try await Mailer.send(
                        subject: "MatterServer: server is down",
                        body: """
                        The matter-server is not running on this Mac.

                        \(reason)

                        Open the MatterServer menu → Show Logs for details.
                        """,
                        config: config)
                    self.log.appendSystem("Server-down alert emailed to \(recipient)")
                } catch {
                    self.log.appendSystem("Server-down alert email failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func bootstrap() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        server.start()
        backup.startScheduling()
        updateChecker.startScheduling()
    }

    func shutdown() {
        server.terminateNow()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon (also set via LSUIElement)
        env.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.shutdown()
    }
}

@main
struct MatterServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let env = delegate.env

        MenuBarExtra {
            MenuContentView()
                .environmentObject(env.settings)
                .environmentObject(env.server)
                .environmentObject(env.backup)
                .environmentObject(env.loginItem)
        } label: {
            MenuBarLabel(server: env.server)
        }

        Settings {
            SettingsView()
                .environmentObject(env.settings)
                .environmentObject(env.server)
                .environmentObject(env.backup)
                .environmentObject(env.loginItem)
                .environmentObject(env.updateChecker)
        }

        Window("Matter Server Logs", id: "logs") {
            LogView()
                .environmentObject(env.log)
                .environmentObject(env.server)
                .environmentObject(env.settings)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Monochrome menu-bar icon that reflects the server status. SF Symbols render
/// as template images, so AppKit tints them for light/dark menu bars.
struct MenuBarLabel: View {
    @ObservedObject var server: ServerController

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel("Matter Server")
    }

    private var symbolName: String {
        // Mesh of connected nodes — echoes the Matter logo, clearly distinct
        // from the house/HomeKit glyph. Status via filled vs. outline, with a
        // dedicated alert glyph for crashes.
        switch server.status {
        case .running: return "point.3.filled.connected.trianglepath.dotted"
        case .starting, .stopping: return "point.3.connected.trianglepath.dotted"
        case .stopped: return "point.3.connected.trianglepath.dotted"
        case .crashed: return "exclamationmark.triangle.fill"
        }
    }
}
