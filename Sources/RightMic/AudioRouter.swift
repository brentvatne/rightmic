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

    // MARK: - Private

    private var cancellable: AnyCancellable?
    private var currentDeviceUID: String?
    private weak var monitor: DeviceMonitor?

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
    }

    // MARK: - Public

    /// Stop routing and clean up shared memory. Call on app termination.
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
        NSLog("[RightMic] Routing started: \(deviceName) -> RightMic")
    }

    private func stopCapture() {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }

        if currentDeviceUID != nil {
            ringBufferWriter.close()
            NSLog("[RightMic] Routing stopped")
        }
        currentDeviceUID = nil
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

    guard let au = router.audioUnit,
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

    // Write the rendered frames into the ring buffer for the HAL driver
    router.ringBufferWriter.write(frames: buffer, frameCount: Int(inNumberFrames))

    return noErr
}
