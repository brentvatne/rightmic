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

    // MARK: - Sample Rate Conversion

    /// AudioConverter for resampling when device rate != 48000 Hz.
    fileprivate var audioConverter: AudioConverterRef?

    /// Native channel count of the current capture device (1 = mono, 2 = stereo).
    /// Set during configureAudioUnit before the capture callback starts.
    fileprivate var captureChannels: UInt32 = UInt32(RingBufferWriter.channelCount)
    /// Output buffer for the sample rate converter (48kHz data).
    fileprivate var converterOutputBuffer: UnsafeMutablePointer<Float>?
    fileprivate let converterOutputCapacity: UInt32 = 8192
    /// Temporary state used by the converter's input callback.
    fileprivate var converterInputPtr: UnsafePointer<Float>?
    fileprivate var converterInputFramesLeft: UInt32 = 0

    // MARK: - Private

    private var cancellable: AnyCancellable?
    private var currentDeviceUID: String?
    private weak var monitor: DeviceMonitor?

    /// The device that was system default before we switched to RightMic.
    private var savedDefaultDeviceID: AudioDeviceID?

    /// Prevents spamming render error logs from the real-time thread.
    fileprivate var renderErrorLogged: Bool = false

    // MARK: - Lifecycle

    init(monitor: DeviceMonitor) {
        self.monitor = monitor
        allocateRenderBuffer()
        allocateConverterOutputBuffer()

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
        deallocateConverterOutputBuffer()
        captureActiveFlag.deinitialize(count: 1)
        captureActiveFlag.deallocate()
    }

    // MARK: - Public

    /// Stop routing, restore system default, and clean up. Call on app termination.
    func shutdown() {
        stopCapture()
        ringBufferWriter.unlink()
    }

    // MARK: - Device Change Handling

    private func handleDeviceChange(_ entry: PriorityEntry?) {
        NSLog("[RightMic] handleDeviceChange called: %@", entry?.name ?? "nil")
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
        let t0 = CFAbsoluteTimeGetCurrent()
        NSLog("[RightMic] startCapture: begin device=%@ (%@)", deviceName, deviceUID)

        // Already capturing from this device
        if currentDeviceUID == deviceUID && audioUnit != nil {
            NSLog("[RightMic] startCapture: already capturing from this device, skipping")
            return
        }

        // Stop existing capture first
        stopCapture()

        // Look up the AudioDeviceID from the monitor's live device list
        guard let deviceID = monitor?.inputDevices.first(where: { $0.uid == deviceUID })?.deviceID else {
            NSLog("[RightMic] Cannot find deviceID for: \(deviceUID)")
            return
        }

        // Open the shared ring buffer
        do {
            let t1 = CFAbsoluteTimeGetCurrent()
            try ringBufferWriter.open()
            NSLog("[RightMic] startCapture: ringBufferWriter.open took %.3fs", CFAbsoluteTimeGetCurrent() - t1)
        } catch {
            NSLog("[RightMic] Failed to open ring buffer: \(error)")
            return
        }

        // Configure and start the AUHAL capture unit
        let t2 = CFAbsoluteTimeGetCurrent()
        guard configureAudioUnit(deviceID: deviceID) else {
            NSLog("[RightMic] Failed to configure audio unit for: \(deviceName)")
            ringBufferWriter.close()
            return
        }
        NSLog("[RightMic] startCapture: configureAudioUnit took %.3fs", CFAbsoluteTimeGetCurrent() - t2)

        currentDeviceUID = deviceUID

        // Reset diagnostic state
        renderErrorLogged = false

        // Mark capture active (checked by the real-time callback)
        captureActiveFlag.pointee = 1
        OSMemoryBarrier()

        // Set system default input to RightMic virtual device
        let t3 = CFAbsoluteTimeGetCurrent()
        claimSystemDefault()
        NSLog("[RightMic] startCapture: claimSystemDefault took %.3fs", CFAbsoluteTimeGetCurrent() - t3)

        NSLog("[RightMic] Routing started: \(deviceName) (id=\(deviceID)) -> RightMic [total %.3fs]",
              CFAbsoluteTimeGetCurrent() - t0)
    }

    private func stopCapture() {
        let t0 = CFAbsoluteTimeGetCurrent()
        NSLog("[RightMic] stopCapture: begin (currentDevice=%@)", currentDeviceUID ?? "nil")

        // Signal the real-time callback to stop before tearing down
        captureActiveFlag.pointee = 0
        OSMemoryBarrier()

        if let au = audioUnit {
            let t1 = CFAbsoluteTimeGetCurrent()
            AudioOutputUnitStop(au)
            NSLog("[RightMic] stopCapture: AudioOutputUnitStop took %.3fs", CFAbsoluteTimeGetCurrent() - t1)

            let t2 = CFAbsoluteTimeGetCurrent()
            AudioUnitUninitialize(au)
            NSLog("[RightMic] stopCapture: AudioUnitUninitialize took %.3fs", CFAbsoluteTimeGetCurrent() - t2)

            let t3 = CFAbsoluteTimeGetCurrent()
            AudioComponentInstanceDispose(au)
            NSLog("[RightMic] stopCapture: AudioComponentInstanceDispose took %.3fs", CFAbsoluteTimeGetCurrent() - t3)

            audioUnit = nil
        }

        destroyAudioConverter()

        if currentDeviceUID != nil {
            let t4 = CFAbsoluteTimeGetCurrent()
            ringBufferWriter.close()
            NSLog("[RightMic] stopCapture: ringBufferWriter.close took %.3fs", CFAbsoluteTimeGetCurrent() - t4)

            let t5 = CFAbsoluteTimeGetCurrent()
            restoreSystemDefault()
            NSLog("[RightMic] stopCapture: restoreSystemDefault took %.3fs", CFAbsoluteTimeGetCurrent() - t5)

            NSLog("[RightMic] Routing stopped")
        }
        currentDeviceUID = nil
        NSLog("[RightMic] stopCapture: total %.3fs", CFAbsoluteTimeGetCurrent() - t0)
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

        // Query the device's native format on the input (hardware) side of bus 1
        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioUnitGetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1,
            &deviceFormat, &formatSize
        )
        let captureRate: Float64
        let captureChannels: UInt32
        if fmtStatus == noErr && deviceFormat.mSampleRate > 0 {
            captureRate = deviceFormat.mSampleRate
            // Clamp to the ring buffer's channel count (mono or stereo).
            // Per Apple TN2091, AUHAL silences extra client channels that have no
            // corresponding hardware channel, so we must match the hardware channel count
            // to avoid getting a silent right channel from a mono microphone.
            captureChannels = deviceFormat.mChannelsPerFrame >= 1
                ? min(deviceFormat.mChannelsPerFrame, UInt32(RingBufferWriter.channelCount))
                : UInt32(RingBufferWriter.channelCount)
            NSLog("[RightMic] Device native format: %.0f Hz, %d ch, %d bits, flags=0x%X",
                  deviceFormat.mSampleRate, deviceFormat.mChannelsPerFrame,
                  deviceFormat.mBitsPerChannel, deviceFormat.mFormatFlags)
        } else {
            captureRate = 48000.0
            captureChannels = UInt32(RingBufferWriter.channelCount)
            NSLog("[RightMic] Could not query device format (status=%d), assuming 48kHz stereo", fmtStatus)
        }
        self.captureChannels = captureChannels
        let captureBytesPerFrame = captureChannels * 4  // 32-bit float

        // Set our desired format on the output (client) side of bus 1.
        // Use the device's native sample rate and channel count to avoid -10863 errors
        // with virtual devices and to prevent channel mismatches with mono hardware.
        // Sample rate and mono→stereo upmixing are handled after rendering.
        var format = AudioStreamBasicDescription(
            mSampleRate: captureRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                        | kAudioFormatFlagsNativeEndian
                        | kAudioFormatFlagIsPacked,
            mBytesPerPacket: captureBytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: captureBytesPerFrame,
            mChannelsPerFrame: captureChannels,
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

        // Create sample rate converter if device rate differs from 48kHz
        destroyAudioConverter()
        if captureRate != 48000.0 {
            var srcFormat = format
            var dstFormat = format
            dstFormat.mSampleRate = 48000.0

            var converter: AudioConverterRef?
            let convStatus = AudioConverterNew(&srcFormat, &dstFormat, &converter)
            guard convStatus == noErr, let converter else {
                NSLog("[RightMic] Failed to create AudioConverter (%.0f -> 48000): %d",
                      captureRate, convStatus)
                AudioComponentInstanceDispose(au)
                return false
            }
            // Use highest quality SRC to minimise audible artefacts on non-48kHz devices.
            var quality = UInt32(kAudioConverterQuality_Max)
            AudioConverterSetProperty(converter,
                                      kAudioConverterSampleRateConverterQuality,
                                      UInt32(MemoryLayout<UInt32>.size),
                                      &quality)
            audioConverter = converter
            NSLog("[RightMic] Created sample rate converter: %.0f Hz -> 48000 Hz (%d ch)",
                  captureRate, captureChannels)
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
            destroyAudioConverter()
            AudioComponentInstanceDispose(au)
            return false
        }

        // Initialize
        status = AudioUnitInitialize(au)
        guard status == noErr else {
            NSLog("[RightMic] AudioUnitInitialize failed: \(status)")
            destroyAudioConverter()
            AudioComponentInstanceDispose(au)
            return false
        }

        // Start
        status = AudioOutputUnitStart(au)
        guard status == noErr else {
            NSLog("[RightMic] AudioOutputUnitStart failed: \(status)")
            AudioUnitUninitialize(au)
            destroyAudioConverter()
            AudioComponentInstanceDispose(au)
            return false
        }

        audioUnit = au
        return true
    }

    // MARK: - Audio Converter

    private func destroyAudioConverter() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
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

    private func allocateConverterOutputBuffer() {
        let count = Int(converterOutputCapacity) * RingBufferWriter.channelCount
        converterOutputBuffer = .allocate(capacity: count)
        converterOutputBuffer?.initialize(repeating: 0, count: count)
    }

    private func deallocateConverterOutputBuffer() {
        guard let buf = converterOutputBuffer else { return }
        let count = Int(converterOutputCapacity) * RingBufferWriter.channelCount
        buf.deinitialize(count: count)
        buf.deallocate()
        converterOutputBuffer = nil
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

    let channels = router.captureChannels
    let bytesPerFrame = channels * 4  // 32-bit float, captureChannels wide
    let bytesNeeded = inNumberFrames * bytesPerFrame

    // Point an AudioBufferList at our pre-allocated buffer
    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: bytesNeeded,
            mData: UnsafeMutableRawPointer(buffer)
        )
    )

    // Render input audio from the AUHAL into our buffer
    let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else {
        // Log first render failure only (avoid spamming from real-time thread)
        if router.renderErrorLogged == false {
            router.renderErrorLogged = true
            NSLog("[RightMic] AudioUnitRender failed: %d", status)
        }
        return status
    }

    // Write to ring buffer, converting sample rate if needed
    if let converter = router.audioConverter,
       let outBuffer = router.converterOutputBuffer {
        // Set up converter input state (read by converterInputCallback)
        router.converterInputPtr = UnsafePointer(buffer)
        router.converterInputFramesLeft = inNumberFrames

        var outputFrames = router.converterOutputCapacity

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: outputFrames * bytesPerFrame,
                mData: UnsafeMutableRawPointer(outBuffer)
            )
        )

        let convStatus = AudioConverterFillComplexBuffer(
            converter,
            converterInputCallback,
            inRefCon,
            &outputFrames,
            &outputBufferList,
            nil
        )

        if convStatus == noErr || convStatus == 100 {
            // Upmix mono to stereo before writing so the ring buffer always receives
            // 2-channel interleaved audio regardless of the hardware channel count.
            if router.captureChannels == 1 {
                upmixMonoToStereo(buffer: outBuffer, frameCount: Int(outputFrames))
            }
            router.ringBufferWriter.write(frames: outBuffer, frameCount: Int(outputFrames))
        }
    } else {
        // No conversion needed — write directly (with upmix for mono devices).
        if router.captureChannels == 1 {
            upmixMonoToStereo(buffer: buffer, frameCount: Int(inNumberFrames))
        }
        router.ringBufferWriter.write(frames: buffer, frameCount: Int(inNumberFrames))
    }

    return noErr
}

// MARK: - AudioConverter Input Callback

/// Called by AudioConverterFillComplexBuffer to pull input data for sample rate conversion.
private func converterInputCallback(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData else {
        ioNumberDataPackets.pointee = 0
        return -50 // paramErr
    }

    let router = Unmanaged<AudioRouter>.fromOpaque(inUserData).takeUnretainedValue()

    let available = router.converterInputFramesLeft
    if available == 0 {
        ioNumberDataPackets.pointee = 0
        return 100 // signal end of input data
    }

    let toProvide = min(ioNumberDataPackets.pointee, available)
    let channels = router.captureChannels
    let bytesPerFrame = channels * 4  // 32-bit float, captureChannels wide

    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = channels
    ioData.pointee.mBuffers.mDataByteSize = toProvide * bytesPerFrame
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: router.converterInputPtr!)

    ioNumberDataPackets.pointee = toProvide
    router.converterInputFramesLeft -= toProvide
    router.converterInputPtr = router.converterInputPtr?.advanced(by: Int(toProvide * channels))

    outDataPacketDescription?.pointee = nil
    return noErr
}

// MARK: - Mono to Stereo Upmix

/// Expands mono frames to stereo interleaved in-place by duplicating each sample.
///
/// The buffer must have capacity for at least `2 * frameCount` Float32 values.
/// Works backwards through the array so source samples are never overwritten
/// before they are read.
private func upmixMonoToStereo(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
    for i in stride(from: frameCount - 1, through: 0, by: -1) {
        let sample = buffer[i]
        buffer[i * 2 + 1] = sample  // R
        buffer[i * 2]     = sample  // L
    }
}
