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
    /// Set while a start is being prepared (validating, reclaiming the port).
    /// No child exists yet in that window, so `process == nil` alone would let a
    /// second start slip through.
    private var isPreparing = false
    /// Set when a restart was requested; the relaunch happens once the current
    /// process has fully terminated (see `handleTermination`).
    private var startAfterStop = false
    private var restartAttempt = 0
    private var pendingRestart: DispatchWorkItem?
    private let backoffSeconds: [Double] = [1, 2, 5, 10, 30, 60]

    /// Called once per outage when the server has crashed and failed to recover
    /// (keepalive threshold reached, or a crash with auto-restart off). Never on
    /// a manual stop. Reset when the server next runs successfully.
    var onOutage: ((String) -> Void)?
    private var notifiedOutage = false
    private let failureNotifyThreshold = 5

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
        // The installed matter-server version is read directly from the bundled
        // package.json, so it's correct immediately (no log scraping needed).
        self.detectedVersion = BundledRuntime.installedServerVersion
    }

    // MARK: - Public control

    /// True while a child process handle is alive (running or shutting down), or
    /// while one is about to exist. `isPreparing` has to count: the backup waits
    /// on this before snapshotting, and a start that is still reclaiming the port
    /// has no handle yet but does launch a server moments later.
    var isRunning: Bool { process != nil || isPreparing }

    func start() {
        // Guard on the actual process handle, not just status: while a process
        // is `.stopping` it is not "active" but still alive and holding the
        // storage lock. Spawning a second one here caused the crash loop.
        // `isPreparing` extends that guard over the async preparation below.
        guard process == nil, !isPreparing else {
            log.appendSystem("Start ignored: a server process is already running or starting")
            return
        }
        pendingRestart?.cancel()
        pendingRestart = nil
        Task { await startAsync() }
    }

    private func startAsync() async {
        isPreparing = true
        defer { isPreparing = false }
        // A freshly requested start clears any prior intentional-stop latch; it
        // is re-checked after the reclaim below, which can take seconds.
        intentionalStop = false
        status = .starting
        do {
            try BundledRuntime.validate()
            try FileManager.default.createDirectory(at: settings.storageURL, withIntermediateDirectories: true)
            // Last thing before launching, so the takeover window stays as short
            // as possible: clear an orphan still holding the port.
            await reclaimOrphanServer()
            if intentionalStop {
                status = .stopped
                log.appendSystem("Start cancelled (stopped while reclaiming port \(settings.port))")
                return
            }
            try launch(arguments: BundledRuntime.arguments(for: settings))
        } catch {
            status = .crashed(error.localizedDescription)
            lastError = error.localizedDescription
            log.appendSystem("Start failed: \(error.localizedDescription)")
        }
    }

    /// Stop the server intentionally (no keepalive restart, no outage email).
    func stop() {
        intentionalStop = true
        notifiedOutage = false
        pendingRestart?.cancel()
        pendingRestart = nil
        terminateProcess()
    }

    func restart() {
        log.appendSystem("Restart requested")
        if process != nil {
            // Restart only once the current process has actually terminated
            // (handled in handleTermination), never on a fixed delay.
            startAfterStop = true
            stop()
        } else {
            start()
        }
    }

    /// Synchronously terminate the child before the app exits, so no orphaned
    /// node process survives to hold the storage lock against the next launch.
    func terminateNow() {
        intentionalStop = true
        startAfterStop = false
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let proc = process, proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { kill(pid, SIGKILL) }
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

    // MARK: - Orphan reclaim

    /// Clear an orphaned matter-server still holding our port, so the caller can
    /// launch.
    ///
    /// Normally `terminateNow()` takes our child down with the app, but a hard
    /// app crash or a hung/killed login session never runs it — and the orphaned
    /// node process keeps holding both the port and the matter.js storage lock.
    /// We no longer have a process handle for it, so every keepalive
    /// attempt spawns a second instance that dies at once ("Server failed to
    /// start", exit 1 — the storage lock turns it away even before the port
    /// does): an endless restart loop plus a "keeps crashing" outage email, with
    /// no server under our control. Retrying can never fix that; the sibling apps
    /// needed a reboot (seen 2026-07-16). So take the orphan down first —
    /// SIGTERM, escalating to SIGKILL — and let the caller launch.
    private func reclaimOrphanServer() async {
        guard let pid = orphanServerPID() else { return }
        log.appendSystem("Orphaned matter-server (PID \(pid)) holds port \(settings.port) — terminating it to take over")
        kill(pid, SIGTERM)
        // Wait on the port rather than the PID: a released port is exactly the
        // precondition for launching, and it also covers an unreaped zombie,
        // which still answers kill(pid, 0) but holds no sockets.
        if await portReleased(within: 10) {
            log.appendSystem("Orphaned server terminated — taking over")
            return
        }
        // Safe to be blunt: the storage lock the orphan leaves behind names its
        // PID, so matter.js sees the owner is gone and clears it on next start.
        log.appendSystem("Orphaned server ignored SIGTERM — sending SIGKILL")
        kill(pid, SIGKILL)
        if !(await portReleased(within: 5)) {
            log.appendSystem("Port \(settings.port) still held — the start will most likely fail")
        }
    }

    /// Poll until nobody listens on the server port, up to `seconds`.
    private func portReleased(within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !serverPortIsHeld() { return true }
        }
        return false
    }

    /// PID of a matter-server holding our port that is not our own child, or nil
    /// if there is none.
    ///
    /// Since we are about to send signals, the claim is proven, not guessed. The
    /// port is the authority: if we can bind it, no instance is live and there is
    /// nothing to reclaim. Only when it really is held do we ask who holds it,
    /// and the command line is then checked as a second, independent witness: our
    /// writable server install, its entry script, and this exact storage path.
    /// Nothing but our own instance runs that install against that storage. If it
    /// disagrees, the port belongs to somebody else — we signal nothing and let
    /// matter-server's own start error surface rather than shoot down a
    /// stranger's server. (The bundled `node` is deliberately not part of the
    /// witness: it moves with the .app, while the install and storage paths sit
    /// at stable locations under ~/Library and are already decisive.)
    private func orphanServerPID() -> pid_t? {
        guard serverPortIsHeld(), let pid = portListenerPID() else { return nil }
        guard pid > 0, pid != process?.processIdentifier else { return nil }
        guard kill(pid, 0) == 0 else { return nil }
        guard let command = processCommand(pid),
              command.contains(BundledRuntime.serverDirectory.path),
              command.contains("MatterServer.js"),
              command.contains("--storage-path \(settings.storagePath)") else {
            log.appendSystem("Port \(settings.port) is held, but PID \(pid) does not look like our matter-server — not intervening")
            return nil
        }
        return pid
    }

    /// Whether someone currently listens on the server port — i.e. an instance is
    /// live. Probing by trying to bind it ourselves mirrors what the server's own
    /// startup does (Node's `server.listen`, `SO_REUSEADDR` included — libuv sets
    /// it), and unlike a PID file it cannot go stale: the kernel drops the socket
    /// the moment its holder dies. `SO_REUSEADDR` is what keeps a just-closed
    /// connection lingering in `TIME_WAIT` from reading as a live instance — for
    /// us exactly as for Node.
    ///
    /// The probe is IPv4 even though the server ends up on the IPv6 wildcard
    /// (`server.listen` without a host binds `::` dual-stack; libuv clears
    /// `IPV6_V6ONLY`): binding `0.0.0.0` collides with that dual-stack socket,
    /// and equally with the plain IPv4 socket Node falls back to on a host
    /// without IPv6. The reverse does not hold — with `SO_REUSEADDR` the kernel
    /// happily puts a `::` bind next to an existing `0.0.0.0` one — so IPv4 is
    /// the probe that catches both (measured against the running server).
    private func serverPortIsHeld() -> Bool {
        guard let port = UInt16(exactly: settings.port), port > 0 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0).bigEndian // INADDR_ANY
        let result = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return false }
        return errno == EADDRINUSE
    }

    /// PID listening on the server port, via `lsof`. Nil unless exactly one
    /// process holds it: with several we cannot tell which one to signal, and
    /// guessing is not acceptable when the next step is a kill.
    private func portListenerPID() -> pid_t? {
        let output = runTool("/usr/sbin/lsof", ["-nP", "-iTCP:\(settings.port)", "-sTCP:LISTEN", "-t"]) ?? ""
        let pids = Set(output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) })
        guard pids.count == 1 else { return nil }
        return pids.first
    }

    /// Full command line of `pid`, or nil if it cannot be read.
    private func processCommand(_ pid: pid_t) -> String? {
        runTool("/bin/ps", ["-p", "\(pid)", "-o", "command="])
    }

    /// Trimmed stdout of a command-line tool, or nil if it fails or says nothing.
    private func runTool(_ path: String, _ arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
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
            self.notifiedOutage = false // recovered → allow a future outage to notify again
            // Refresh now that the writable server dir is seeded/updated (the
            // value read at init may have been nil on first launch, and an
            // in-app update changes it).
            self.detectedVersion = BundledRuntime.installedServerVersion
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
            if startAfterStop {
                startAfterStop = false
                start()
            }
            return
        }

        let reason = "exited with code \(code)"
        status = .crashed(reason)
        lastError = reason
        log.appendSystem("Server \(reason)")

        guard settings.autoRestart else {
            // No keepalive: a crash means the server is down now.
            notifyOutageOnce("matter-server crashed (\(reason)) and auto-restart is disabled.")
            return
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = backoffSeconds[min(restartAttempt, backoffSeconds.count - 1)]
        restartAttempt += 1
        log.appendSystem("Auto-restart in \(Int(delay))s (attempt \(restartAttempt))")
        if restartAttempt >= failureNotifyThreshold {
            notifyOutageOnce("matter-server keeps crashing (\(restartAttempt) restart attempts). Last error: \(lastError ?? "unknown").")
        }
        let work = DispatchWorkItem { [weak self] in self?.start() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Fire the outage callback at most once until the server recovers.
    private func notifyOutageOnce(_ reason: String) {
        guard !notifiedOutage else { return }
        notifiedOutage = true
        log.appendSystem("Sustained outage: \(reason)")
        onOutage?(reason)
    }
}
