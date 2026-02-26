import Foundation

/// Checks whether the RightMic HAL driver is installed and the virtual
/// device is visible to CoreAudio.
public enum DriverStatus {

    /// The driver bundle path in the system HAL plug-ins directory.
    public static let driverInstallPath = "/Library/Audio/Plug-Ins/HAL/RightMic.driver"

    /// The UID of the virtual device created by the driver.
    public static let virtualDeviceUID = "com.rightmic.device"

    /// Whether the .driver bundle exists on disk.
    public static var isDriverInstalled: Bool {
        FileManager.default.fileExists(atPath: driverInstallPath)
    }

    /// Whether the RightMic virtual device is currently visible to CoreAudio.
    public static var isVirtualDeviceAvailable: Bool {
        virtualDeviceAudioID != nil
    }

    /// The CoreAudio AudioDeviceID of the RightMic virtual device, or nil
    /// if the driver isn't installed or loaded.
    public static var virtualDeviceAudioID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            if getUID(deviceID) == virtualDeviceUID {
                return deviceID
            }
        }
        return nil
    }

    /// Set the system default input device.
    @discardableResult
    public static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        return status == noErr
    }

    /// Get the current system default input device ID.
    public static var currentDefaultInputDeviceID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func getUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let ptr = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        ptr.initialize(to: nil)
        defer { ptr.deinitialize(count: 1); ptr.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr) == noErr else {
            return nil
        }
        return ptr.pointee as String?
    }
}

import CoreAudio
