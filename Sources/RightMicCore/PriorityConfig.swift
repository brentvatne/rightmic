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

    public init(uid: String, name: String, transportType: AudioDevice.TransportType, enabled: Bool = true) {
        self.uid = uid
        self.name = name
        self.transportType = transportType
        self.enabled = enabled
    }

    public init(from device: AudioDevice, enabled: Bool = true) {
        self.uid = device.uid
        self.name = device.name
        self.transportType = device.transportType
        self.enabled = enabled
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
}
