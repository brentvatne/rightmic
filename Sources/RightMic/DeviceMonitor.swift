import AVFoundation
import Combine
import CoreAudio
import RightMicCore

/// Monitors system audio input devices and publishes changes in real-time.
final class DeviceMonitor: ObservableObject {

    // MARK: - Published State

    @Published var inputDevices: [AudioDevice] = []
    @Published var defaultInputUID: String?
    @Published var permissionGranted: Bool = false
    @Published var priorityConfig = PriorityConfig.load()

    /// The highest-priority enabled device that is currently connected.
    @Published var resolvedDevice: PriorityEntry?

    // MARK: - Private

    private var configSaveCancellable: AnyCancellable?
    private var resolveCancellable: AnyCancellable?
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListListenerInstalled = false
    private var defaultDeviceListenerInstalled = false

    // MARK: - Lifecycle

    init() {
        refreshDevices()
        installDeviceListeners()
        configSaveCancellable = $priorityConfig
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { config in
                config.save()
            }

        // Resolve best device whenever devices or config change
        resolveCancellable = Publishers.CombineLatest($inputDevices, $priorityConfig)
            .map { devices, config in
                let availableUIDs = Set(devices.map(\.uid))
                return config.bestDevice(availableUIDs: availableUIDs)
            }
            .removeDuplicates { (a: PriorityEntry?, b: PriorityEntry?) in a?.uid == b?.uid }
            .sink { [weak self] best in
                guard let self else { return }
                if self.resolvedDevice?.uid != best?.uid {
                    if let best {
                        NSLog("[RightMic] Resolved device: \(best.name) (\(best.transportType.rawValue))")
                    } else {
                        NSLog("[RightMic] No priority device available")
                    }
                }
                self.resolvedDevice = best
            }
    }

    deinit {
        removeDeviceListeners()
    }

    // MARK: - Permission

    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { [weak self] in
                self?.permissionGranted = true
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { [weak self] in
                    self?.permissionGranted = granted
                    completion(granted)
                }
            }
        default:
            DispatchQueue.main.async { [weak self] in
                self?.permissionGranted = false
                completion(false)
            }
        }
    }

    // MARK: - Device Enumeration

    func refreshDevices() {
        let devices = Self.enumerateInputDevices()
        let defaultUID = Self.getDefaultInputDeviceUID()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inputDevices = devices
            self.defaultInputUID = defaultUID
            self.initializePriorityIfEmpty()
        }
    }

    /// On first run, seed the priority list with all currently connected input devices.
    private func initializePriorityIfEmpty() {
        guard priorityConfig.entries.isEmpty, !inputDevices.isEmpty else { return }
        priorityConfig.entries = inputDevices.map { PriorityEntry(from: $0) }
    }

    // MARK: - Priority Config Helpers

    /// Add a device to the end of the priority list.
    func addToPriority(_ device: AudioDevice) {
        guard !priorityConfig.entries.contains(where: { $0.uid == device.uid }) else { return }
        priorityConfig.entries.append(PriorityEntry(from: device))
    }

    /// Whether a device UID is currently connected.
    func isDeviceAvailable(_ uid: String) -> Bool {
        inputDevices.contains { $0.uid == uid }
    }

    /// Connected devices not yet in the priority list.
    var availableToAdd: [AudioDevice] {
        let priorityUIDs = Set(priorityConfig.entries.map(\.uid))
        return inputDevices.filter { !priorityUIDs.contains($0.uid) }
    }

    static func enumerateInputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputChannels(deviceID) else { return nil }
            let uid = getDeviceUID(deviceID) ?? "unknown-\(deviceID)"
            // Skip our own virtual device to prevent feedback loops
            if uid == DriverStatus.virtualDeviceUID { return nil }
            let name = getDeviceName(deviceID) ?? "Unknown Device"
            let transport = getTransportType(deviceID)
            return AudioDevice(deviceID: deviceID, name: name, uid: uid, transportType: transport)
        }
    }

    // MARK: - System Default

    static func getDefaultInputDeviceUID() -> String? {
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
        return getDeviceUID(deviceID)
    }

    // MARK: - Device Property Helpers

    private static func getStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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

    private static func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func getTransportType(_ deviceID: AudioDeviceID) -> AudioDevice.TransportType {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType) == noErr else {
            return .unknown
        }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        default: return .unknown
        }
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let bufferListRaw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListRaw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListRaw) == noErr else {
            return false
        }

        let bufferList = bufferListRaw.assumingMemoryBound(to: AudioBufferList.self).pointee
        return bufferList.mNumberBuffers > 0
    }

    // MARK: - Device Change Listeners

    private func installDeviceListeners() {
        let ptr = Unmanaged.passUnretained(self).toOpaque()

        if !deviceListListenerInstalled {
            let status = AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &deviceListAddress,
                deviceListChangeCallback,
                ptr
            )
            if status == noErr { deviceListListenerInstalled = true }
        }

        if !defaultDeviceListenerInstalled {
            let status = AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultDeviceAddress,
                deviceListChangeCallback,
                ptr
            )
            if status == noErr { defaultDeviceListenerInstalled = true }
        }
    }

    private func removeDeviceListeners() {
        let ptr = Unmanaged.passUnretained(self).toOpaque()

        if deviceListListenerInstalled {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &deviceListAddress,
                deviceListChangeCallback,
                ptr
            )
            deviceListListenerInstalled = false
        }

        if defaultDeviceListenerInstalled {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultDeviceAddress,
                deviceListChangeCallback,
                ptr
            )
            defaultDeviceListenerInstalled = false
        }
    }

    fileprivate func handleDeviceChange() {
        refreshDevices()
    }
}

// CoreAudio C-function callback for device list/default changes.
private func deviceListChangeCallback(
    objectID: AudioObjectID,
    numberAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(clientData).takeUnretainedValue()
    monitor.handleDeviceChange()
    return noErr
}
