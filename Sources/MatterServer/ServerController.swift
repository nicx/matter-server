import Foundation

/// Supervises the bundled `matter-server` Node.js process: start/stop/restart,
/// crash detection with exponential-backoff keepalive, log capture and version
/// detection.
@MainActor
final class ServerController: ObservableObject {

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case crashed(String)

        var isActive: Bool {
            switch self {
            case .running, .starting: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var startedAt: Date?
    @Published private(set) var detectedVersion: String?
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private let log: LogStore

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Set while we are deliberately stopping, so the termination handler does
    /// not treat the exit as a crash and restart it.
    private var intentionalStop = false
    private var restartAttempt = 0
    private var pendingRestart: DispatchWorkItem?
    private let backoffSeconds: [Double] = [1, 2, 5, 10, 30, 60]

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    // MARK: - Public control

    func start() {
        guard !status.isActive else { return }
        pendingRestart?.cancel()
        pendingRestart = nil

        do {
            try BundledRuntime.validate()
            try FileManager.default.createDirectory(at: settings.storageURL, withIntermediateDirectories: true)
            let args = try BundledRuntime.arguments(for: settings)
            try launch(arguments: args)
        } catch {
            status = .crashed(error.localizedDescription)
            lastError = error.localizedDescription
            log.appendSystem("Start failed: \(error.localizedDescription)")
        }
    }

    /// Stop the server intentionally (no keepalive restart).
    func stop() {
        intentionalStop = true
        pendingRestart?.cancel()
        pendingRestart = nil
        terminateProcess()
    }

    func restart() {
        log.appendSystem("Restart requested")
        stop()
        // Give the OS a moment to release the port before relaunching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.start()
        }
    }

    /// Used by the backup flow: stop for maintenance and report whether the
    /// server was actually running so the caller can decide to restart it.
    func stopForMaintenance() -> Bool {
        let wasActive = status.isActive
        if wasActive { stop() }
        return wasActive
    }

    var uptimeDescription: String? {
        guard status == .running, let startedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    // MARK: - Process lifecycle

    private func launch(arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = BundledRuntime.nodeExecutableURL
        proc.arguments = arguments
        proc.currentDirectoryURL = BundledRuntime.serverDirectory

        var env = ProcessInfo.processInfo.environment
        let nodeBin = BundledRuntime.nodeExecutableURL.deletingLastPathComponent().path
        env["PATH"] = nodeBin + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        installReader(outPipe)
        installReader(errPipe)

        proc.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                self?.handleTermination(code: code)
            }
        }

        intentionalStop = false
        status = .starting
        startedAt = nil
        lastError = nil
        log.appendSystem("Starting matter-server on port \(settings.port) (storage: \(settings.storagePath))")

        try proc.run()
        process = proc
        stdoutPipe = outPipe
        stderrPipe = errPipe

        // matter.js does not emit a machine-readable "ready" event we can rely
        // on; treat the process as running shortly after a successful spawn and
        // let the keepalive handle an immediate crash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.status == .starting else { return }
            self.status = .running
            self.startedAt = Date()
            self.restartAttempt = 0
        }
    }

    private func installReader(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.log.append(text)
                self?.detectVersion(in: text)
            }
        }
    }

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else { return }
        if status == .running || status == .starting { status = .stopping }
        proc.terminate() // SIGTERM
        // Hard-kill fallback if it does not exit promptly.
        let pid = proc.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func handleTermination(code: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        startedAt = nil

        if intentionalStop {
            status = .stopped
            log.appendSystem("Server stopped")
            return
        }

        let reason = "exited with code \(code)"
        status = .crashed(reason)
        lastError = reason
        log.appendSystem("Server \(reason)")

        guard settings.autoRestart else { return }
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = backoffSeconds[min(restartAttempt, backoffSeconds.count - 1)]
        restartAttempt += 1
        log.appendSystem("Auto-restart in \(Int(delay))s (attempt \(restartAttempt))")
        let work = DispatchWorkItem { [weak self] in self?.start() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func detectVersion(in text: String) {
        guard detectedVersion == nil else { return }
        // Best-effort: look for a semver near the word "version" or "matter-server".
        let pattern = #"(?:matter-server|version)[^0-9]{0,12}(\d+\.\d+\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, range: range),
           let r = Range(match.range(at: 1), in: text) {
            detectedVersion = String(text[r])
        }
    }
}
