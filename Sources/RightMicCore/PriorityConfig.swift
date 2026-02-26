import Foundation

/// A single entry in the user's priority-ordered device list.
public struct PriorityEntry: Codable, Identifiable, Equatable {
    public var id: String { uid }

    /// CoreAudio UID of the device.
    public let uid: String

    /// Last-known display name (for when the device is disconnected).
    public var name: String

    /// Last-known transport type.
    public let transportType: AudioDevice.TransportType

    /// Whether this device is included in priority routing.
    public var enabled: Bool

    /// UID of another device this one depends on. If set, this device is only
    /// considered available when the dependency is connected. Useful for virtual
    /// devices (e.g. Loopback) that wrap a physical input.
    public var dependsOn: String?

    public init(uid: String, name: String, transportType: AudioDevice.TransportType, enabled: Bool = true, dependsOn: String? = nil) {
        self.uid = uid
        self.name = name
        self.transportType = transportType
        self.enabled = enabled
        self.dependsOn = dependsOn
    }

    public init(from device: AudioDevice, enabled: Bool = true) {
        self.uid = device.uid
        self.name = device.name
        self.transportType = device.transportType
        self.enabled = enabled
        self.dependsOn = nil
    }
}

/// Persisted priority configuration. Entries are ordered by priority (first = highest).
public struct PriorityConfig: Codable, Equatable {
    public var entries: [PriorityEntry]

    public init(entries: [PriorityEntry] = []) {
        self.entries = entries
    }

    // MARK: - Persistence

    private static var configDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RightMic")
    }

    public static var configFileURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    public static func load() -> PriorityConfig {
        guard let data = try? Data(contentsOf: configFileURL),
              let config = try? JSONDecoder().decode(PriorityConfig.self, from: data) else {
            return PriorityConfig()
        }
        return config
    }

    public func save() {
        let dir = Self.configDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.configFileURL, options: .atomic)
    }

    // MARK: - Queries

    /// Returns the highest-priority enabled entry whose UID matches one of the available UIDs.
    public func bestDevice(availableUIDs: Set<String>) -> PriorityEntry? {
        entries.first { $0.enabled && availableUIDs.contains($0.uid) }
    }

    // MARK: - Reconciliation

    /// Sync entries with the current set of connected devices.
    ///
    /// - Adds new devices not yet in the list
    /// - Updates the UID of an existing entry when a device reconnects with a new
    ///   CoreAudio UID (matched by name + transport type)
    /// - Updates names if a device was renamed
    /// - Removes stale disconnected duplicates (same name + transport type as a
    ///   connected entry but with a different UID)
    ///
    /// - Parameter connectedDevices: The currently connected input devices.
    /// - Parameter excludingUID: A UID to skip (e.g. the virtual device UID).
    public mutating func reconcile(connectedDevices: [AudioDevice], excludingUID: String? = nil) {
        let connectedUIDs = Set(connectedDevices.map(\.uid))
        let knownUIDs = Set(entries.map(\.uid))

        for device in connectedDevices {
            if device.uid == excludingUID { continue }

            if knownUIDs.contains(device.uid) {
                // UID already known — update the name if it changed
                if let idx = entries.firstIndex(where: { $0.uid == device.uid }),
                   entries[idx].name != device.name {
                    entries[idx].name = device.name
                }
            } else if let idx = entries.firstIndex(where: {
                $0.name == device.name && $0.transportType == device.transportType && !connectedUIDs.contains($0.uid)
            }) {
                // Device reconnected with a new UID — update the existing entry in place
                entries[idx] = PriorityEntry(
                    uid: device.uid,
                    name: device.name,
                    transportType: device.transportType,
                    enabled: entries[idx].enabled,
                    dependsOn: entries[idx].dependsOn
                )
            } else {
                entries.append(PriorityEntry(from: device))
            }
        }

        // Remove stale duplicates: disconnected entries that share name + transport
        // type with a currently connected entry.
        let connectedKeys = Set(
            entries.filter { connectedUIDs.contains($0.uid) }
                   .map { "\($0.name)\t\($0.transportType.rawValue)" }
        )
        entries.removeAll { entry in
            !connectedUIDs.contains(entry.uid)
                && connectedKeys.contains("\(entry.name)\t\(entry.transportType.rawValue)")
        }
    }
}
