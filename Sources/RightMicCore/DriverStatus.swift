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
    /// This checks the live device list, so it returns true only if the driver
    /// is installed AND coreaudiod has loaded it.
    public static var isVirtualDeviceAvailable: Bool {
        // Import CoreAudio inline to keep RightMicCore framework-light
        // (this file only runs on macOS where CoreAudio is always available).
        return checkDeviceExists()
    }

    private static func checkDeviceExists() -> Bool {
        // Use the same CoreAudio enumeration pattern as DeviceMonitor.
        // We look for a device with our known UID.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return false }

        for deviceID in deviceIDs {
            if getUID(deviceID) == virtualDeviceUID {
                return true
            }
        }
        return false
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
