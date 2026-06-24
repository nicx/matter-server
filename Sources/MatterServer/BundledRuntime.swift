import Foundation

/// Resolves the bundled Node.js runtime and the vendored `matter-server`
/// package entry point, and builds the argument list for launching the server.
///
/// Layout produced by `Scripts/bundle-runtime.sh`:
/// ```
/// Runtime/
///   node/bin/node          # universal Node.js binary
///   server/                # `npm install matter-server` prefix
///     node_modules/matter-server/...
///     .entry               # absolute-from-server-dir path to the bin JS
/// ```
/// In a packaged `.app` this lives under `Contents/Resources/Runtime`; during
/// `swift run` we fall back to `<packageRoot>/Runtime`. Both can be overridden
/// with the `MATTER_NODE_PATH` / `MATTER_SERVER_DIR` environment variables.
///
/// `node` (+ bundled `npm`) stay in the signed bundle (immutable). The mutable
/// `server/` install is seeded on first launch into a WRITABLE copy under
/// `~/Library/Application Support/MatterServer/runtime/server` so the in-app
/// updater can `npm install matter-server@latest` there without touching — and
/// thus invalidating — the code-signed bundle.
enum BundledRuntime {

    enum RuntimeError: LocalizedError {
        case nodeMissing(String)
        case serverEntryMissing(String)

        var errorDescription: String? {
            switch self {
            case .nodeMissing(let path):
                return "Node.js runtime not found at \(path). Run Scripts/bundle-runtime.sh."
            case .serverEntryMissing(let dir):
                return "matter-server entry point not found under \(dir). Run Scripts/bundle-runtime.sh."
            }
        }
    }

    /// Root directory containing `node/` and `server/`.
    static var runtimeRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MATTER_RUNTIME_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Runtime", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("node").path) {
                return bundled
            }
        }
        // Dev fallback: <packageRoot>/Runtime, derived from this file's location.
        // BundledRuntime.swift -> MatterServer -> Sources -> <packageRoot>
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot.appendingPathComponent("Runtime", isDirectory: true)
    }

    static var nodeExecutableURL: URL {
        if let override = ProcessInfo.processInfo.environment["MATTER_NODE_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return runtimeRoot.appendingPathComponent("node/bin/node")
    }

    /// Read-only `server/` seed shipped inside the bundle (or dev `Runtime/`).
    /// Used to populate the writable copy on first launch (offline-capable).
    static var bundledServerSeed: URL {
        runtimeRoot.appendingPathComponent("server", isDirectory: true)
    }

    /// `npm` CLI inside the bundled Node runtime, used for in-app updates.
    /// (Kept by `bundle-runtime.sh`; we invoke it as `node npm-cli.js …`.)
    static var npmCliURL: URL {
        runtimeRoot.appendingPathComponent("node/lib/node_modules/npm/bin/npm-cli.js")
    }

    /// Writable location of the (updatable) `matter-server` install. Lives
    /// OUTSIDE the code-signed `.app` so in-app `npm install` doesn't break the
    /// bundle signature — same pattern as the sibling apps' `~/Library/…` payloads.
    static var writableServerDirectory: URL {
        // Mirrors AppSettings.defaultSupportDirectory() (…/MatterServer) but
        // inlined to stay non-isolated (AppSettings is @MainActor).
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MatterServer/runtime/server", isDirectory: true)
    }

    /// The server install the running process uses. Defaults to the writable
    /// copy; overridable for development via `MATTER_SERVER_DIR`.
    static var serverDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MATTER_SERVER_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return writableServerDirectory
    }

    /// Seed the writable server directory from the bundled seed on first launch
    /// (so the very first start works offline, before any npm update). Idempotent
    /// and a no-op when `MATTER_SERVER_DIR` overrides the location.
    @discardableResult
    static func ensureServerSeeded() -> Bool {
        if ProcessInfo.processInfo.environment["MATTER_SERVER_DIR"] != nil { return true }
        let fm = FileManager.default
        let dest = writableServerDirectory
        let installed = dest.appendingPathComponent("node_modules/matter-server/package.json")
        if fm.fileExists(atPath: installed.path) { return true }
        let seed = bundledServerSeed
        guard fm.fileExists(atPath: seed.appendingPathComponent("node_modules/matter-server/package.json").path) else {
            return false // no seed present; an explicit update/install is required
        }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: seed, to: dest)
            return true
        } catch {
            return false
        }
    }

    /// Absolute path to the JavaScript file that starts the server.
    static func resolveServerEntry() throws -> URL {
        let dir = serverDirectory
        // Preferred: an `.entry` file written by the bundling script.
        let entryFile = dir.appendingPathComponent(".entry")
        if let recorded = try? String(contentsOf: entryFile, encoding: .utf8) {
            let trimmed = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let url = trimmed.hasPrefix("/")
                    ? URL(fileURLWithPath: trimmed)
                    : dir.appendingPathComponent(trimmed)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        // Fallback: common entry points within the package. MatterServer.js is
        // the runnable `main`; cli.js only parses arguments.
        let candidates = [
            "node_modules/matter-server/dist/esm/MatterServer.js",
            "node_modules/matter-server/dist/cjs/MatterServer.js",
            "node_modules/matter-server/dist/MatterServer.js",
        ]
        for candidate in candidates {
            let url = dir.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw RuntimeError.serverEntryMissing(dir.path)
    }

    /// Validate that the runtime is present before attempting to launch.
    static func validate() throws {
        let node = nodeExecutableURL
        guard FileManager.default.isExecutableFile(atPath: node.path) else {
            throw RuntimeError.nodeMissing(node.path)
        }
        // Populate the writable copy from the bundled seed on first launch.
        ensureServerSeeded()
        _ = try resolveServerEntry()
    }

    /// Build the launch arguments for `node`: node flags first, then the server
    /// entry script, then the server's own CLI flags (parsed by matter-server's
    /// cli.js via commander).
    @MainActor
    static func arguments(for settings: AppSettings) throws -> [String] {
        // `--enable-source-maps` is a Node flag and must precede the script path
        // (matches the package's own `npm run server`).
        var args = ["--enable-source-maps", try resolveServerEntry().path]
        args += ["--storage-path", settings.storagePath]
        args += ["--log-level", settings.logLevel]
        args += ["--port", String(settings.port)]
        if !settings.primaryInterface.isEmpty {
            args += ["--primary-interface", settings.primaryInterface]
        }
        // matter-server has no plain `--ble`; Bluetooth is selected by HCI
        // adapter id (Linux/D-Bus concept — typically unavailable on macOS).
        if !settings.bluetoothAdapter.isEmpty {
            args += ["--bluetooth-adapter", settings.bluetoothAdapter]
        }
        // Accept test/development device certificates (non-CSA DACs), e.g. DIY
        // Tasmota devices. The flag uses commander's preset(true), so passing it
        // bare enables it.
        if settings.enableTestNetDcl {
            args += ["--enable-test-net-dcl"]
        }
        return args
    }

    // MARK: - Versions (read directly from the bundled package.json files)

    /// Version of the `matter-server` package — i.e. the matter.js-based server
    /// that gets updated via npm. This is what the update check compares against.
    static var installedServerVersion: String? {
        version(ofPackage: "node_modules/matter-server/package.json")
    }

    /// Version of the underlying matter.js SDK (`@matter/*`), distinct from the
    /// server package version.
    static var matterSdkVersion: String? {
        version(ofPackage: "node_modules/@matter/general/package.json")
    }

    /// Read a package version from the writable install, falling back to the
    /// bundled seed. The fallback matters on first launch, before the writable
    /// copy has been seeded, so the UI shows the real version immediately.
    private static func version(ofPackage relativePath: String) -> String? {
        packageVersion(at: serverDirectory.appendingPathComponent(relativePath))
            ?? packageVersion(at: bundledServerSeed.appendingPathComponent(relativePath))
    }

    private static func packageVersion(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String else { return nil }
        return version
    }
}
