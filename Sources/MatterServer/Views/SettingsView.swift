import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ServerSettingsTab()
                .tabItem { Label("Server", systemImage: "server.rack") }
            BackupSettingsTab()
                .tabItem { Label("Backup", systemImage: "externaldrive.badge.timemachine") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480)
        .padding()
    }
}

// MARK: - Server

private struct ServerSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController

    var body: some View {
        Form {
            Section {
                TextField("Port", value: $settings.port, format: .number.grouping(.never))

                Picker("Log level", selection: $settings.logLevel) {
                    ForEach(AppSettings.logLevels, id: \.self) { Text($0) }
                }

                Toggle("Auto-restart on crash", isOn: $settings.autoRestart)
            }

            Section {
                LabeledContent("Server storage") {
                    VStack(alignment: .trailing, spacing: 4) {
                        PathChooser(path: $settings.storagePath, chooseDirectory: true)
                        if !settings.storagePathIsDefault {
                            Button("Reset to default") { settings.resetStoragePathToDefault() }
                                .controlSize(.small)
                        }
                    }
                }

                if settings.storagePath == settings.backupDirectory {
                    Label("Storage and backup folder should differ.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                TextField("Primary interface", text: $settings.primaryInterface,
                          prompt: Text("e.g. en0 — leave empty for all"))

                TextField("Bluetooth adapter (HCI id)", text: $settings.bluetoothAdapter,
                          prompt: Text("empty = off — usually N/A on macOS"))
            } header: {
                Text("Advanced")
            } footer: {
                Text("Storage holds the controller's fabric keys, commissioned nodes and certificates. Most users never change this; changing it does not move existing data.")
            }

            Section {
                HStack {
                    Text("Changes apply on next start.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply & Restart") { server.restart() }
                        .disabled(!server.status.isActive)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Backup

private struct BackupSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var backup: BackupManager

    var body: some View {
        Form {
            Toggle("Daily backup enabled", isOn: $settings.backupEnabled)
                .onChange(of: settings.backupEnabled) { backup.rescheduleTimer() }

            LabeledContent("Backup folder") {
                PathChooser(path: $settings.backupDirectory, chooseDirectory: true)
            }

            DatePicker("Daily at", selection: backupTime, displayedComponents: .hourAndMinute)

            Stepper("Keep last \(settings.backupRetention) backups",
                    value: $settings.backupRetention, in: 1...90)

            Toggle("Stop server during backup (consistent snapshot)", isOn: $settings.stopDuringBackup)

            Divider()

            HStack {
                Button(backup.isBusy ? "Backing up…" : "Back Up Now") {
                    Task { await backup.runBackup(reason: "manual") }
                }
                .disabled(backup.isBusy)
                Spacer()
                if let err = backup.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }

            Section("Existing backups") {
                if backup.backups.isEmpty {
                    Text("No backups yet").foregroundStyle(.secondary)
                } else {
                    ForEach(backup.backups, id: \.self) { url in
                        HStack {
                            Text(url.lastPathComponent).font(.callout)
                            Spacer()
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("Restore…") { confirmRestore(url) }
                                .disabled(backup.isBusy)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { backup.refreshList() }
    }

    private var backupTime: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = settings.backupHour
                c.minute = settings.backupMinute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                settings.backupHour = c.hour ?? 0
                settings.backupMinute = c.minute ?? 0
                backup.rescheduleTimer()
            }
        )
    }

    private func confirmRestore(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Restore from \(url.lastPathComponent)?"
        alert.informativeText = "This stops the server and replaces the current storage directory. The current state is saved as a pre-restore backup first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await backup.restore(from: url) }
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var loginItem: LoginItemManager
    @EnvironmentObject var server: ServerController
    @State private var latestVersion: String?
    @State private var checking = false
    @State private var checkError: String?

    var body: some View {
        Form {
            Toggle("Start at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            if let err = loginItem.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            LabeledContent("Installed server version", value: server.detectedVersion ?? "unknown")

            Section("Updates") {
                HStack {
                    Button(checking ? "Checking…" : "Check for matter-server Update") {
                        Task { await checkForUpdate() }
                    }
                    .disabled(checking)
                    Spacer()
                    if let latest = latestVersion {
                        Text("Latest: \(latest)").font(.caption)
                    }
                }
                if let err = checkError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Text("Update by re-running Scripts/bundle-runtime.sh and rebuilding the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    private func checkForUpdate() async {
        checking = true
        checkError = nil
        defer { checking = false }
        guard let url = URL(string: "https://registry.npmjs.org/matter-server/latest") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = obj["version"] as? String {
                latestVersion = version
            } else {
                checkError = "Unexpected response from npm registry"
            }
        } catch {
            checkError = error.localizedDescription
        }
    }
}

// MARK: - Reusable path chooser

private struct PathChooser: View {
    @Binding var path: String
    var chooseDirectory: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(path).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary).font(.callout)
            Spacer()
            Button("Choose…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = chooseDirectory
        panel.canChooseFiles = !chooseDirectory
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
