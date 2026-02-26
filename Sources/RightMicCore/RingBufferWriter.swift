import Foundation

/// Manages the app-side of the shared memory ring buffer that feeds
/// audio data to the RightMic HAL driver.
///
/// The driver (running in coreaudiod) opens the same file as read-only
/// and serves the audio to any app that selects "RightMic" as its input.
///
/// Usage (Phase 5 will call this from the audio capture callback):
///
///     let writer = RingBufferWriter()
///     try writer.open()
///     writer.write(frames: audioData, frameCount: 512)
///     writer.close()
///
public final class RingBufferWriter {

    // MARK: - Constants (must match RightMicDriver.h)

    public static let sharedMemoryPath = "/tmp/com.rightmic.audio"
    public static let ringBufferFrames: Int = 16384
    public static let channelCount: Int = 2
    public static let bytesPerFrame: Int = channelCount * MemoryLayout<Float32>.size
    public static let headerSize: Int = 64  // sizeof(RightMicRingBufferHeader)
    public static let dataSize: Int = ringBufferFrames * bytesPerFrame
    public static let totalSize: Int = headerSize + dataSize

    // MARK: - State

    public let path: String
    private var fd: Int32 = -1
    private var mappedPtr: UnsafeMutableRawPointer?
    private var header: UnsafeMutablePointer<RingBufferHeader>?
    private var audioData: UnsafeMutablePointer<Float>?

    public var isOpen: Bool { mappedPtr != nil }

    // MARK: - Ring Buffer Header Layout (matches C struct)

    /// Mirror of `RightMicRingBufferHeader` from the driver.
    /// Uses the same memory layout so the driver and app share state.
    struct RingBufferHeader {
        var writeHead: UInt64
        var readHead: UInt64
        var active: UInt32
        var sampleRate: UInt32
        var channels: UInt32
        var _pad: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)  // 9 x UInt32 = 36 bytes → total 64
    }

    // MARK: - Lifecycle

    public init(path: String = RingBufferWriter.sharedMemoryPath) {
        self.path = path
    }

    deinit {
        close()
    }

    // MARK: - Open / Close

    /// Create and map the shared file for IPC with the driver.
    public func open() throws {
        guard !isOpen else { return }
        assert(MemoryLayout<RingBufferHeader>.size == Self.headerSize,
               "RingBufferHeader size mismatch with headerSize constant")

        // Create the backing file. O_NOFOLLOW prevents symlink attacks.
        // Permissions: owner read-write, others read-only (0644).
        // The HAL driver runs as _coreaudiod and needs read access.
        fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw RingBufferError.openFailed(errno: errno)
        }

        // Ensure correct permissions even if the file already existed with
        // stricter permissions from a previous version.
        fchmod(fd, 0o644)

        // Validate the opened file descriptor
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno
            Darwin.close(fd)
            fd = -1
            throw RingBufferError.fstatFailed(errno: e)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            fd = -1
            throw RingBufferError.notRegularFile
        }
        guard st.st_uid == getuid() else {
            Darwin.close(fd)
            fd = -1
            throw RingBufferError.ownerMismatch
        }

        // Set size
        guard ftruncate(fd, off_t(Self.totalSize)) == 0 else {
            Darwin.close(fd)
            fd = -1
            throw RingBufferError.ftruncateFailed(errno: errno)
        }

        // Map into our address space
        let ptr = mmap(nil, Self.totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard ptr != MAP_FAILED else {
            Darwin.close(fd)
            fd = -1
            throw RingBufferError.mmapFailed(errno: errno)
        }

        mappedPtr = ptr
        header = ptr!.assumingMemoryBound(to: RingBufferHeader.self)
        audioData = ptr!.advanced(by: Self.headerSize).assumingMemoryBound(to: Float.self)

        // Initialize header
        header!.pointee.writeHead = 0
        header!.pointee.readHead = 0
        header!.pointee.sampleRate = UInt32(48000)
        header!.pointee.channels = UInt32(Self.channelCount)
        setActive(true)

        NSLog("[RightMic] Ring buffer opened (size: \(Self.totalSize) bytes)")
    }

    /// Unmap and close the shared file.
    public func close() {
        if header != nil {
            setActive(false)
        }

        if let ptr = mappedPtr {
            // Zero all audio data to prevent residual leakage
            memset(ptr, 0, Self.totalSize)
            msync(ptr, Self.totalSize, MS_SYNC)
            munmap(ptr, Self.totalSize)
            mappedPtr = nil
        }

        header = nil
        audioData = nil

        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Remove the shared file from disk.
    /// Call this when the app exits to clean up.
    public func unlink() {
        Darwin.unlink(path)
    }

    // MARK: - Write

    /// Write interleaved Float32 audio frames to the ring buffer.
    /// Called from the audio capture callback (real-time safe path).
    ///
    /// - Parameters:
    ///   - frames: Pointer to interleaved Float32 samples
    ///   - frameCount: Number of frames to write
    public func write(frames: UnsafePointer<Float>, frameCount: Int) {
        guard let header = header, let audioData = audioData else { return }

        let ringFrames = Self.ringBufferFrames
        let channels = Self.channelCount
        var wHead = header.pointee.writeHead
        var written = 0

        while written < frameCount {
            let ringIndex = Int(wHead % UInt64(ringFrames))
            let contiguous = ringFrames - ringIndex
            let chunk = min(frameCount - written, contiguous)
            let sampleOffset = written * channels
            let ringOffset = ringIndex * channels

            memcpy(audioData.advanced(by: ringOffset),
                   frames.advanced(by: sampleOffset),
                   chunk * Self.bytesPerFrame)

            wHead += UInt64(chunk)
            written += chunk
        }

        // Memory barrier ensures the driver sees the audio data before the updated head
        OSMemoryBarrier()
        header.pointee.writeHead = wHead
    }

    // MARK: - Active Flag

    private func setActive(_ active: Bool) {
        guard let header = header else { return }
        header.pointee.active = active ? 1 : 0
    }

    // MARK: - Errors

    public enum RingBufferError: Error, CustomStringConvertible {
        case openFailed(errno: Int32)
        case fstatFailed(errno: Int32)
        case notRegularFile
        case ownerMismatch
        case ftruncateFailed(errno: Int32)
        case mmapFailed(errno: Int32)

        public var description: String {
            switch self {
            case .openFailed(let e):      return "open failed: \(String(cString: strerror(e)))"
            case .fstatFailed(let e):     return "fstat failed: \(String(cString: strerror(e)))"
            case .notRegularFile:         return "shared memory path is not a regular file"
            case .ownerMismatch:          return "shared memory file owned by another user"
            case .ftruncateFailed(let e): return "ftruncate failed: \(String(cString: strerror(e)))"
            case .mmapFailed(let e):      return "mmap failed: \(String(cString: strerror(e)))"
            }
        }
    }
}
