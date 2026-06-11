import SwiftUI
import AppKit

/// The menu shown when the user clicks the menu-bar icon.
struct MenuContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var backup: BackupManager
    @EnvironmentObject var loginItem: LoginItemManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if let version = server.detectedVersion {
            Text("Version \(version)").font(.caption)
        }

        Divider()

        Button("Start") { server.start() }
            .disabled(server.status.isActive)
        Button("Stop") { server.stop() }
            .disabled(!server.status.isActive)
        Button("Restart") { server.restart() }
            .disabled(!server.status.isActive)

        Divider()

        Button("Open Dashboard") { NSWorkspace.shared.open(settings.dashboardURL) }
            .disabled(server.status != .running)
        Button("Show Logs…") { openWindow(id: "logs"); NSApp.activate(ignoringOtherApps: true) }

        Divider()

        Button(backup.isBusy ? "Backing up…" : "Back Up Now") {
            Task { await backup.runBackup(reason: "manual") }
        }
        .disabled(backup.isBusy)
        if let last = backup.lastBackupDate {
            Text("Last backup: \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption)
        }

        Divider()

        Toggle("Start at Login", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        ))

        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit MatterServer") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch server.status {
        case .stopped: return "Server stopped"
        case .starting: return "Server starting…"
        case .stopping: return "Server stopping…"
        case .crashed(let reason): return "Server crashed (\(reason))"
        case .running:
            let uptime = server.uptimeDescription.map { " · up \($0)" } ?? ""
            return "Server running · :\(settings.port)\(uptime)"
        }
    }
}
