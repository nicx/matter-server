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

    init() {
        let settings = AppSettings.shared
        let log = LogStore()
        let server = ServerController(settings: settings, log: log)
        self.settings = settings
        self.log = log
        self.server = server
        self.backup = BackupManager(settings: settings, server: server, log: log)
        self.loginItem = LoginItemManager()
    }

    func bootstrap() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        server.start()
        backup.startScheduling()
    }

    func shutdown() {
        server.stop()
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
