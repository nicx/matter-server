import Foundation

/// User-facing configuration, persisted in `UserDefaults`.
///
/// Every property writes through to `UserDefaults` on `didSet` so that the
/// `ServerController` and `BackupManager` always read the current values, and
/// SwiftUI views can bind directly via `@Published`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: Server

    @Published var port: Int { didSet { defaults.set(port, forKey: Keys.port) } }
    @Published var storagePath: String { didSet { defaults.set(storagePath, forKey: Keys.storagePath) } }
    @Published var primaryInterface: String { didSet { defaults.set(primaryInterface, forKey: Keys.primaryInterface) } }
    /// Bluetooth adapter HCI id passed as `--bluetooth-adapter`; empty = disabled.
    @Published var bluetoothAdapter: String { didSet { defaults.set(bluetoothAdapter, forKey: Keys.bluetoothAdapter) } }
    @Published var logLevel: String { didSet { defaults.set(logLevel, forKey: Keys.logLevel) } }
    @Published var autoRestart: Bool { didSet { defaults.set(autoRestart, forKey: Keys.autoRestart) } }
    /// Allow commissioning test/development devices (non-CSA-certified DACs) by
    /// passing `--enable-test-net-dcl`. Needed for DIY devices (e.g. Tasmota).
    @Published var enableTestNetDcl: Bool { didSet { defaults.set(enableTestNetDcl, forKey: Keys.enableTestNetDcl) } }
    /// Turn off the server's OTA provider (`--disable-ota`) so it stops pushing
    /// firmware updates to devices. OTA downloads over Thread flood sleepy
    /// devices' subscriptions (mass flapping) and some devices loop on an update.
    @Published var disableOta: Bool { didSet { defaults.set(disableOta, forKey: Keys.disableOta) } }

    // MARK: Backup

    @Published var backupDirectory: String { didSet { defaults.set(backupDirectory, forKey: Keys.backupDirectory) } }
    @Published var backupEnabled: Bool { didSet { defaults.set(backupEnabled, forKey: Keys.backupEnabled) } }
    /// Hour of day (0-23) for the daily backup.
    @Published var backupHour: Int { didSet { defaults.set(backupHour, forKey: Keys.backupHour) } }
    /// Minute of hour (0-59) for the daily backup.
    @Published var backupMinute: Int { didSet { defaults.set(backupMinute, forKey: Keys.backupMinute) } }
    /// How many of the most recent backup archives to keep.
    @Published var backupRetention: Int { didSet { defaults.set(backupRetention, forKey: Keys.backupRetention) } }
    /// Stop the server during the snapshot for a consistent backup, then restart it.
    @Published var stopDuringBackup: Bool { didSet { defaults.set(stopDuringBackup, forKey: Keys.stopDuringBackup) } }

    // MARK: Update notifications

    /// Email the recipient when a newer matter-server release is available.
    @Published var updateEmailEnabled: Bool { didSet { defaults.set(updateEmailEnabled, forKey: Keys.updateEmailEnabled) } }
    /// Email when the server crashes and fails to recover (not on manual stop).
    @Published var serverDownEmailEnabled: Bool { didSet { defaults.set(serverDownEmailEnabled, forKey: Keys.serverDownEmailEnabled) } }
    @Published var updateEmailRecipient: String { didSet { defaults.set(updateEmailRecipient, forKey: Keys.updateEmailRecipient) } }
    @Published var updateEmailSender: String { didSet { defaults.set(updateEmailSender, forKey: Keys.updateEmailSender) } }
    /// Local mail relay (MailRelay) — sends plaintext SMTP, no auth/TLS here.
    @Published var smtpHost: String { didSet { defaults.set(smtpHost, forKey: Keys.smtpHost) } }
    @Published var smtpPort: Int { didSet { defaults.set(smtpPort, forKey: Keys.smtpPort) } }

    static let logLevels = ["critical", "error", "warning", "info", "debug", "verbose"]

    private init() {
        port = (defaults.object(forKey: Keys.port) as? Int) ?? 5580
        storagePath = (defaults.string(forKey: Keys.storagePath)) ?? AppSettings.defaultStoragePath
        primaryInterface = (defaults.string(forKey: Keys.primaryInterface)) ?? ""
        bluetoothAdapter = (defaults.string(forKey: Keys.bluetoothAdapter)) ?? ""
        logLevel = (defaults.string(forKey: Keys.logLevel)) ?? "info"
        autoRestart = (defaults.object(forKey: Keys.autoRestart) as? Bool) ?? true
        enableTestNetDcl = defaults.bool(forKey: Keys.enableTestNetDcl)
        disableOta = defaults.bool(forKey: Keys.disableOta)

        backupDirectory = (defaults.string(forKey: Keys.backupDirectory)) ?? AppSettings.defaultBackupDirectory
        backupEnabled = (defaults.object(forKey: Keys.backupEnabled) as? Bool) ?? true
        backupHour = (defaults.object(forKey: Keys.backupHour) as? Int) ?? 3
        backupMinute = (defaults.object(forKey: Keys.backupMinute) as? Int) ?? 0
        backupRetention = (defaults.object(forKey: Keys.backupRetention) as? Int) ?? 7
        stopDuringBackup = (defaults.object(forKey: Keys.stopDuringBackup) as? Bool) ?? true

        updateEmailEnabled = defaults.bool(forKey: Keys.updateEmailEnabled)
        serverDownEmailEnabled = defaults.bool(forKey: Keys.serverDownEmailEnabled)
        updateEmailRecipient = defaults.string(forKey: Keys.updateEmailRecipient) ?? ""
        updateEmailSender = defaults.string(forKey: Keys.updateEmailSender) ?? "MatterServer <matterserver@localhost>"
        smtpHost = defaults.string(forKey: Keys.smtpHost) ?? "127.0.0.1"
        smtpPort = (defaults.object(forKey: Keys.smtpPort) as? Int) ?? 2525
    }

    var storageURL: URL { URL(fileURLWithPath: storagePath, isDirectory: true) }
    var backupURL: URL { URL(fileURLWithPath: backupDirectory, isDirectory: true) }
    var dashboardURL: URL { URL(string: "http://localhost:\(port)")! }

    /// Shared mail configuration for update and server-down notifications.
    var mailConfig: Mailer.Config {
        Mailer.Config(host: smtpHost, port: smtpPort, sender: updateEmailSender, recipient: updateEmailRecipient)
    }

    static func defaultSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MatterServer", isDirectory: true)
    }

    /// Single source of truth for the default locations, also used by the reset
    /// action so the UI and `init` never drift apart.
    static var defaultStoragePath: String {
        defaultSupportDirectory().appendingPathComponent("storage").path
    }
    static var defaultBackupDirectory: String {
        defaultSupportDirectory().appendingPathComponent("backups").path
    }

    var storagePathIsDefault: Bool { storagePath == AppSettings.defaultStoragePath }

    func resetStoragePathToDefault() {
        storagePath = AppSettings.defaultStoragePath
    }

    private enum Keys {
        static let port = "server.port"
        static let storagePath = "server.storagePath"
        static let primaryInterface = "server.primaryInterface"
        static let bluetoothAdapter = "server.bluetoothAdapter"
        static let logLevel = "server.logLevel"
        static let autoRestart = "server.autoRestart"
        static let enableTestNetDcl = "server.enableTestNetDcl"
        static let disableOta = "server.disableOta"
        static let backupDirectory = "backup.directory"
        static let backupEnabled = "backup.enabled"
        static let backupHour = "backup.hour"
        static let backupMinute = "backup.minute"
        static let backupRetention = "backup.retention"
        static let stopDuringBackup = "backup.stopDuring"
        static let updateEmailEnabled = "update.emailEnabled"
        static let serverDownEmailEnabled = "update.serverDownEmailEnabled"
        static let updateEmailRecipient = "update.emailRecipient"
        static let updateEmailSender = "update.emailSender"
        static let smtpHost = "update.smtpHost"
        static let smtpPort = "update.smtpPort"
    }
}
