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

    static var serverDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MATTER_SERVER_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return runtimeRoot.appendingPathComponent("server", isDirectory: true)
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
        return args
    }

    // MARK: - Versions (read directly from the bundled package.json files)

    /// Version of the `matter-server` package — i.e. the matter.js-based server
    /// that gets updated via npm. This is what the update check compares against.
    static var installedServerVersion: String? {
        packageVersion(at: serverDirectory.appendingPathComponent("node_modules/matter-server/package.json"))
    }

    /// Version of the underlying matter.js SDK (`@matter/*`), distinct from the
    /// server package version.
    static var matterSdkVersion: String? {
        packageVersion(at: serverDirectory.appendingPathComponent("node_modules/@matter/general/package.json"))
    }

    private static func packageVersion(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String else { return nil }
        return version
    }
}
