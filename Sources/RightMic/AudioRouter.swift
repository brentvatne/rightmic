import Accelerate
import AudioToolbox
import Combine
import CoreAudio
import RightMicCore

/// Routes audio from the resolved real input device to the shared ring buffer.
/// The HAL driver reads from this buffer to serve the "RightMic" virtual device.
final class AudioRouter {

    // MARK: - State (fileprivate for callback access)

    fileprivate var audioUnit: AudioComponentInstance?
    fileprivate let ringBufferWriter = RingBufferWriter()
    fileprivate var renderBuffer: UnsafeMutablePointer<Float>?
    fileprivate let renderBufferFrameCapacity: UInt32 = 4096

    /// Atomic flag checked by the real-time callback. Set to 0 before
    /// tearing down the audio unit so the callback can bail out safely.
    /// Allocated on the heap so the pointer is stable across moves.
    fileprivate let captureActiveFlag: UnsafeMutablePointer<Int32> = {
        let ptr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        ptr.initialize(to: 0)
        return ptr
    }()

    /// Peak sample magnitude written by the real-time callback, read by the silence timer.
    fileprivate let peakLevel: UnsafeMutablePointer<Float32> = {
        let ptr = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        ptr.initialize(to: 0)
        return ptr
    }()

    // MARK: - Private

    private var cancellable: AnyCancellable?
    private var currentDeviceUID: String?
    private weak var monitor: DeviceMonitor?

    /// The device that was system default before we switched to RightMic.
    private var savedDefaultDeviceID: AudioDeviceID?

    /// Silence detection: how many consecutive timer ticks we've seen silence.
    private var silentTicks: Int = 0
    /// Threshold in seconds before declaring a device silent.
    private static let silenceTimeout: Int = 3
    /// Peak level (linear) below which we consider silence.
    private static let silenceThreshold: Float32 = 0.001 // ~-60dB
    /// Timer that polls peak level from the callback.
    private var silenceTimer: Timer?
    /// True until the first silence check completes for a new device.
    private var warmingUp: Bool = false

    // MARK: - Lifecycle

    init(monitor: DeviceMonitor) {
        self.monitor = monitor
        allocateRenderBuffer()

        cancellable = monitor.$resolvedDevice
            .removeDuplicates { $0?.uid == $1?.uid }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in
                self?.handleDeviceChange(entry)
            }
    }

    deinit {
        stopCapture()
        deallocateRenderBuffer()
        captureActiveFlag.deinitialize(count: 1)
        captureActiveFlag.deallocate()
        peakLevel.deinitialize(count: 1)
        peakLevel.deallocate()
    }

    // MARK: - Public

    /// Stop routing, restore system default, and clean up. Call on app termination.
    func shutdown() {
        stopCapture()
        ringBufferWriter.unlink()
    }

    // MARK: - Device Change Handling

    private func handleDeviceChange(_ entry: PriorityEntry?) {
        guard let entry = entry else {
            stopCapture()
            return
        }

        // Never route from our own virtual device (feedback loop)
        if entry.uid == DriverStatus.virtualDeviceUID {
            NSLog("[RightMic] Skipping routing from own virtual device")
            stopCapture()
            return
        }

        startCapture(deviceUID: entry.uid, deviceName: entry.name)
    }

    // MARK: - Capture Control

    private func startCapture(deviceUID: String, deviceName: String) {
        // Already capturing from this device
        if currentDeviceUID == deviceUID && audioUnit != nil { return }

        // Stop existing capture first
        stopCapture()

        // Look up the AudioDeviceID from the monitor's live device list
        guard let deviceID = monitor?.inputDevices.first(where: { $0.uid == deviceUID })?.deviceID else {
            NSLog("[RightMic] Cannot find deviceID for: \(deviceUID)")
            return
        }

        // Open the shared ring buffer
        do {
            try ringBufferWriter.open()
        } catch {
            NSLog("[RightMic] Failed to open ring buffer: \(error)")
            return
        }

        // Configure and start the AUHAL capture unit
        guard configureAudioUnit(deviceID: deviceID) else {
            NSLog("[RightMic] Failed to configure audio unit for: \(deviceName)")
            ringBufferWriter.close()
            return
        }

        currentDeviceUID = deviceUID

        // Mark capture active (checked by the real-time callback)
        captureActiveFlag.pointee = 1
        OSMemoryBarrier()

        // Start silence detection with clean state
        peakLevel.pointee = 0
        silentTicks = 0
        warmingUp = true
        monitor?.isWarming = true
        startSilenceTimer()

        // Set system default input to RightMic virtual device
        claimSystemDefault()

        NSLog("[RightMic] Routing started: \(deviceName) -> RightMic")
    }

    private func stopCapture() {
        // Signal the real-time callback to stop before tearing down
        captureActiveFlag.pointee = 0
        OSMemoryBarrier()

        stopSilenceTimer()
        if warmingUp {
            warmingUp = false
            monitor?.isWarming = false
        }

        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }

        if currentDeviceUID != nil {
            ringBufferWriter.close()
            restoreSystemDefault()
            NSLog("[RightMic] Routing stopped")
        }
        currentDeviceUID = nil
    }

    // MARK: - System Default Management

    private func claimSystemDefault() {
        guard let virtualID = DriverStatus.virtualDeviceAudioID else {
            NSLog("[RightMic] Virtual device not available, cannot set system default")
            return
        }

        // Save the current default so we can restore it later
        if let currentDefault = DriverStatus.currentDefaultInputDeviceID,
           currentDefault != virtualID {
            savedDefaultDeviceID = currentDefault
        }

        if DriverStatus.setDefaultInputDevice(virtualID) {
            NSLog("[RightMic] System default input set to RightMic")
        } else {
            NSLog("[RightMic] Failed to set system default input")
        }
    }

    private func restoreSystemDefault() {
        guard let savedID = savedDefaultDeviceID else { return }
        if DriverStatus.setDefaultInputDevice(savedID) {
            NSLog("[RightMic] System default input restored")
        }
        savedDefaultDeviceID = nil
    }

    // MARK: - Silence Detection

    private func startSilenceTimer() {
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
    }

    private func stopSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private func checkSilence() {
        guard let uid = currentDeviceUID, let monitor = monitor else { return }

        if warmingUp {
            warmingUp = false
            monitor.isWarming = false
        }

        // Read and reset the peak level from the callback
        let peak = peakLevel.pointee
        peakLevel.pointee = 0

        // Skip silence detection for the forced device
        if monitor.forcedDeviceUID == uid { return }

        if peak < Self.silenceThreshold {
            silentTicks += 1
            if silentTicks == Self.silenceTimeout {
                NSLog("[RightMic] Silence detected on \(uid) for \(Self.silenceTimeout)s, marking silent")
                monitor.markDeviceSilent(uid)
            }
        } else {
            if silentTicks >= Self.silenceTimeout {
                NSLog("[RightMic] Audio resumed on \(uid), clearing silent flag")
                monitor.clearDeviceSilent(uid)
            }
            silentTicks = 0
        }
    }

    // MARK: - AUHAL Configuration

    private func configureAudioUnit(deviceID: AudioDeviceID) -> Bool {
        // Find the HAL Output audio component
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            NSLog("[RightMic] HALOutput component not found")
            return false
        }

        var au: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &au) == noErr, let au else {
            NSLog("[RightMic] Failed to create audio unit")
            return false
        }

        // Enable input on bus 1
        var enableIO: UInt32 = 1
        var status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1,
            &enableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            NSLog("[RightMic] EnableIO input failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Disable output on bus 0
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0,
            &disableIO, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            NSLog("[RightMic] EnableIO output failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Set the input device
        var inputDevice = deviceID
        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &inputDevice, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            NSLog("[RightMic] Set input device failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Set our desired format on the output (client) side of bus 1.
        // CoreAudio will convert from the device's native format to this.
        var format = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                        | kAudioFormatFlagsNativeEndian
                        | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(RingBufferWriter.bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(RingBufferWriter.bytesPerFrame),
            mChannelsPerFrame: UInt32(RingBufferWriter.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            NSLog("[RightMic] Set stream format failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Set input callback (fires when new audio is available)
        var callbackStruct = AURenderCallbackStruct(
            inputProc: auInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0,
            &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            NSLog("[RightMic] Set input callback failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Initialize
        status = AudioUnitInitialize(au)
        guard status == noErr else {
            NSLog("[RightMic] AudioUnitInitialize failed: \(status)")
            AudioComponentInstanceDispose(au)
            return false
        }

        // Start
        status = AudioOutputUnitStart(au)
        guard status == noErr else {
            NSLog("[RightMic] AudioOutputUnitStart failed: \(status)")
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            return false
        }

        audioUnit = au
        return true
    }

    // MARK: - Render Buffer

    private func allocateRenderBuffer() {
        let count = Int(renderBufferFrameCapacity) * RingBufferWriter.channelCount
        renderBuffer = .allocate(capacity: count)
        renderBuffer?.initialize(repeating: 0, count: count)
    }

    private func deallocateRenderBuffer() {
        guard let buf = renderBuffer else { return }
        let count = Int(renderBufferFrameCapacity) * RingBufferWriter.channelCount
        buf.deinitialize(count: count)
        buf.deallocate()
        renderBuffer = nil
    }
}

// MARK: - Audio Unit Callback

/// C-function callback invoked by CoreAudio on the real-time audio thread
/// when new input frames are available from the hardware device.
private func auInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let router = Unmanaged<AudioRouter>.fromOpaque(inRefCon).takeUnretainedValue()

    // Bail out if capture is being torn down on the main thread
    guard router.captureActiveFlag.pointee != 0,
          let au = router.audioUnit,
          let buffer = router.renderBuffer,
          inNumberFrames <= router.renderBufferFrameCapacity else {
        return noErr
    }

    let bytesNeeded = inNumberFrames * UInt32(RingBufferWriter.bytesPerFrame)

    // Point an AudioBufferList at our pre-allocated buffer
    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: UInt32(RingBufferWriter.channelCount),
            mDataByteSize: bytesNeeded,
            mData: UnsafeMutableRawPointer(buffer)
        )
    )

    // Render input audio from the AUHAL into our buffer
    let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else { return status }

    // Track peak level for silence detection (vDSP SIMD-optimized)
    var peak: Float32 = 0
    vDSP_maxmgv(buffer, 1, &peak, vDSP_Length(inNumberFrames) * vDSP_Length(RingBufferWriter.channelCount))
    if peak > router.peakLevel.pointee {
        router.peakLevel.pointee = peak
    }

    // Write the rendered frames into the ring buffer for the HAL driver
    router.ringBufferWriter.write(frames: buffer, frameCount: Int(inNumberFrames))

    return noErr
}
