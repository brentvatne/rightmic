import Foundation

/// Represents an audio input device on the system.
public struct AudioDevice: Identifiable, Equatable, Hashable {
    /// Stable identity based on CoreAudio UID (persists across reboots).
    public var id: String { uid }

    /// CoreAudio AudioDeviceID (transient, not stable across reboots).
    public let deviceID: UInt32

    /// Human-readable device name.
    public let name: String

    /// CoreAudio UID — stable persistent identifier for this device.
    public let uid: String

    /// How the device is physically connected.
    public let transportType: TransportType

    public enum TransportType: String, Codable, CaseIterable {
        case builtIn = "Built-in"
        case usb = "USB"
        case bluetooth = "Bluetooth"
        case virtual = "Virtual"
        case aggregate = "Aggregate"
        case unknown = "Unknown"
    }

    public init(deviceID: UInt32, name: String, uid: String, transportType: TransportType) {
        self.deviceID = deviceID
        self.name = name
        self.uid = uid
        self.transportType = transportType
    }
}

// Custom Codable: deviceID is transient (runtime-only), so we exclude it from encoding.
extension AudioDevice: Codable {
    enum CodingKeys: String, CodingKey {
        case name, uid, transportType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = 0
        self.name = try container.decode(String.self, forKey: .name)
        self.uid = try container.decode(String.self, forKey: .uid)
        self.transportType = try container.decode(TransportType.self, forKey: .transportType)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(uid, forKey: .uid)
        try container.encode(transportType, forKey: .transportType)
    }
}
