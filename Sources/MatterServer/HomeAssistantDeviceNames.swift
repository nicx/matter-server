import Foundation

/// Best-effort lookup of Home Assistant's friendly device names for Matter
/// nodes, read directly from HA's own device registry file.
///
/// HA is the only place these names exist: Apple Home does not write them
/// back into a device's Matter Basic Information cluster (its `NodeLabel`
/// attribute stays empty even for devices the user renamed in the Home app),
/// so matter-server itself has nothing better to offer. This is tightly
/// coupled to this Mac's specific, single HA instance — matches how
/// `AppSettings`/`BundledRuntime` already hardcode this setup — and is
/// read-only. It silently returns nothing if HA isn't there or the storage
/// format has moved, since this is only ever used to make a notification
/// email more readable, never anything functional.
enum HomeAssistantDeviceNames {
    private static let registryPath =
        NSHomeDirectory() + "/Library/HomeAssistant/config/.storage/core.device_registry"

    /// Node ID → friendly name (the user's own name if they set one, else the
    /// device's model name), for every Matter device HA knows about.
    static func lookup() -> [Int: String] {
        guard let data = FileManager.default.contents(atPath: registryPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let devices = dataObj["devices"] as? [[String: Any]] else { return [:] }

        var result: [Int: String] = [:]
        for device in devices {
            guard let identifiers = device["identifiers"] as? [[String]] else { continue }
            for pair in identifiers {
                // ["matter", "deviceid_<compressedFabricID>-<nodeID hex>-MatterNodeDevice"]
                guard pair.count == 2, pair[0] == "matter", pair[1].contains("MatterNodeDevice") else { continue }
                let parts = pair[1].split(separator: "-")
                guard parts.count >= 2, let nodeID = Int(parts[parts.count - 2], radix: 16) else { continue }
                let userName = (device["name_by_user"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let name = userName ?? (device["name"] as? String) {
                    result[nodeID] = name
                }
            }
        }
        return result
    }
}
