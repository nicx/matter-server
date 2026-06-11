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

    static let logLevels = ["critical", "error", "warning", "info", "debug", "verbose"]

    private init() {
        let support = AppSettings.defaultSupportDirectory()
        port = (defaults.object(forKey: Keys.port) as? Int) ?? 5580
        storagePath = (defaults.string(forKey: Keys.storagePath)) ?? support.appendingPathComponent("storage").path
        primaryInterface = (defaults.string(forKey: Keys.primaryInterface)) ?? ""
        bluetoothAdapter = (defaults.string(forKey: Keys.bluetoothAdapter)) ?? ""
        logLevel = (defaults.string(forKey: Keys.logLevel)) ?? "info"
        autoRestart = (defaults.object(forKey: Keys.autoRestart) as? Bool) ?? true

        backupDirectory = (defaults.string(forKey: Keys.backupDirectory)) ?? support.appendingPathComponent("backups").path
        backupEnabled = (defaults.object(forKey: Keys.backupEnabled) as? Bool) ?? true
        backupHour = (defaults.object(forKey: Keys.backupHour) as? Int) ?? 3
        backupMinute = (defaults.object(forKey: Keys.backupMinute) as? Int) ?? 0
        backupRetention = (defaults.object(forKey: Keys.backupRetention) as? Int) ?? 7
        stopDuringBackup = (defaults.object(forKey: Keys.stopDuringBackup) as? Bool) ?? true
    }

    var storageURL: URL { URL(fileURLWithPath: storagePath, isDirectory: true) }
    var backupURL: URL { URL(fileURLWithPath: backupDirectory, isDirectory: true) }
    var dashboardURL: URL { URL(string: "http://localhost:\(port)")! }

    static func defaultSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MatterServer", isDirectory: true)
    }

    private enum Keys {
        static let port = "server.port"
        static let storagePath = "server.storagePath"
        static let primaryInterface = "server.primaryInterface"
        static let bluetoothAdapter = "server.bluetoothAdapter"
        static let logLevel = "server.logLevel"
        static let autoRestart = "server.autoRestart"
        static let backupDirectory = "backup.directory"
        static let backupEnabled = "backup.enabled"
        static let backupHour = "backup.hour"
        static let backupMinute = "backup.minute"
        static let backupRetention = "backup.retention"
        static let stopDuringBackup = "backup.stopDuring"
    }
}
