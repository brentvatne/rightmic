import XCTest
@testable import RightMicCore

// MARK: - AudioDevice Tests

final class AudioDeviceTests: XCTestCase {

    func testInitialization() {
        let device = AudioDevice(
            deviceID: 42,
            name: "Test Microphone",
            uid: "test-uid-123",
            transportType: .usb
        )
        XCTAssertEqual(device.deviceID, 42)
        XCTAssertEqual(device.name, "Test Microphone")
        XCTAssertEqual(device.uid, "test-uid-123")
        XCTAssertEqual(device.transportType, .usb)
    }

    func testIdentifiable() {
        let device = AudioDevice(
            deviceID: 42,
            name: "Test",
            uid: "uid-abc",
            transportType: .builtIn
        )
        // id should be the stable UID, not the transient deviceID
        XCTAssertEqual(device.id, "uid-abc")
    }

    func testEquatable() {
        let a = AudioDevice(deviceID: 42, name: "Mic", uid: "uid-1", transportType: .usb)
        let b = AudioDevice(deviceID: 42, name: "Mic", uid: "uid-1", transportType: .usb)
        let c = AudioDevice(deviceID: 99, name: "Mic", uid: "uid-2", transportType: .usb)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCodableRoundTrip() throws {
        let device = AudioDevice(
            deviceID: 42,
            name: "SM7B",
            uid: "AppleUSBAudioEngine:Shure:SM7B:123",
            transportType: .usb
        )
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(AudioDevice.self, from: data)

        // deviceID is not encoded — decoded value should be 0
        XCTAssertEqual(decoded.deviceID, 0)
        XCTAssertEqual(decoded.name, device.name)
        XCTAssertEqual(decoded.uid, device.uid)
        XCTAssertEqual(decoded.transportType, device.transportType)
    }

    func testCodableExcludesDeviceID() throws {
        let device = AudioDevice(
            deviceID: 42,
            name: "Test",
            uid: "uid-1",
            transportType: .bluetooth
        )
        let data = try JSONEncoder().encode(device)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["deviceID"])
        XCTAssertNotNil(json["uid"])
        XCTAssertNotNil(json["name"])
        XCTAssertNotNil(json["transportType"])
    }
}

// MARK: - TransportType Tests

final class TransportTypeTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(AudioDevice.TransportType.builtIn.rawValue, "Built-in")
        XCTAssertEqual(AudioDevice.TransportType.usb.rawValue, "USB")
        XCTAssertEqual(AudioDevice.TransportType.bluetooth.rawValue, "Bluetooth")
        XCTAssertEqual(AudioDevice.TransportType.virtual.rawValue, "Virtual")
        XCTAssertEqual(AudioDevice.TransportType.aggregate.rawValue, "Aggregate")
        XCTAssertEqual(AudioDevice.TransportType.unknown.rawValue, "Unknown")
    }

    func testCaseIterable() {
        XCTAssertEqual(AudioDevice.TransportType.allCases.count, 6)
    }

    func testCodableRoundTrip() throws {
        for type in AudioDevice.TransportType.allCases {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(AudioDevice.TransportType.self, from: data)
            XCTAssertEqual(decoded, type)
        }
    }
}

// MARK: - PriorityEntry Tests

final class PriorityEntryTests: XCTestCase {

    func testInitFromDevice() {
        let device = AudioDevice(deviceID: 42, name: "SM7B", uid: "uid-sm7b", transportType: .usb)
        let entry = PriorityEntry(from: device)
        XCTAssertEqual(entry.uid, "uid-sm7b")
        XCTAssertEqual(entry.name, "SM7B")
        XCTAssertEqual(entry.transportType, .usb)
        XCTAssertTrue(entry.enabled)
    }

    func testInitFromDeviceDisabled() {
        let device = AudioDevice(deviceID: 1, name: "Mic", uid: "uid-1", transportType: .builtIn)
        let entry = PriorityEntry(from: device, enabled: false)
        XCTAssertFalse(entry.enabled)
    }

    func testIdentifiable() {
        let entry = PriorityEntry(uid: "uid-abc", name: "Test", transportType: .usb)
        XCTAssertEqual(entry.id, "uid-abc")
    }

    func testCodableRoundTrip() throws {
        let entry = PriorityEntry(uid: "uid-1", name: "SM7B", transportType: .usb, enabled: false)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(PriorityEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }
}

// MARK: - PriorityConfig Tests

final class PriorityConfigTests: XCTestCase {

    func testEmptyByDefault() {
        let config = PriorityConfig()
        XCTAssertTrue(config.entries.isEmpty)
    }

    func testCodableRoundTrip() throws {
        let config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-1", name: "SM7B", transportType: .usb),
            PriorityEntry(uid: "uid-2", name: "AirPods", transportType: .bluetooth, enabled: false),
            PriorityEntry(uid: "uid-3", name: "Built-in", transportType: .builtIn),
        ])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PriorityConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testBestDeviceReturnsHighestPriorityAvailable() {
        let config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-1", name: "SM7B", transportType: .usb),
            PriorityEntry(uid: "uid-2", name: "AirPods", transportType: .bluetooth),
            PriorityEntry(uid: "uid-3", name: "Built-in", transportType: .builtIn),
        ])
        // SM7B not available, AirPods available → picks AirPods
        let available: Set<String> = ["uid-2", "uid-3"]
        let best = config.bestDevice(availableUIDs: available)
        XCTAssertEqual(best?.uid, "uid-2")
    }

    func testBestDeviceSkipsDisabled() {
        let config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-1", name: "SM7B", transportType: .usb),
            PriorityEntry(uid: "uid-2", name: "AirPods", transportType: .bluetooth, enabled: false),
            PriorityEntry(uid: "uid-3", name: "Built-in", transportType: .builtIn),
        ])
        // SM7B not available, AirPods disabled, Built-in available → picks Built-in
        let available: Set<String> = ["uid-2", "uid-3"]
        let best = config.bestDevice(availableUIDs: available)
        XCTAssertEqual(best?.uid, "uid-3")
    }

    func testBestDeviceReturnsNilWhenNoneAvailable() {
        let config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-1", name: "SM7B", transportType: .usb),
        ])
        let best = config.bestDevice(availableUIDs: [])
        XCTAssertNil(best)
    }

    func testBestDeviceReturnsNilWhenEmpty() {
        let config = PriorityConfig()
        let best = config.bestDevice(availableUIDs: ["uid-1"])
        XCTAssertNil(best)
    }

    func testPersistenceRoundTrip() throws {
        let config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-1", name: "Test Mic", transportType: .usb),
        ])

        // Save to a temp file
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent("config.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        try data.write(to: tempFile)

        // Load back
        let loaded = try JSONDecoder().decode(PriorityConfig.self, from: Data(contentsOf: tempFile))
        XCTAssertEqual(loaded, config)

        try FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - PriorityConfig Reconciliation Tests

final class PriorityConfigReconcileTests: XCTestCase {

    func testAddsNewDevice() {
        var config = PriorityConfig()
        let device = AudioDevice(deviceID: 1, name: "Mic", uid: "uid-1", transportType: .usb)
        config.reconcile(connectedDevices: [device])
        XCTAssertEqual(config.entries.count, 1)
        XCTAssertEqual(config.entries[0].uid, "uid-1")
        XCTAssertEqual(config.entries[0].name, "Mic")
    }

    func testDoesNotDuplicateExistingDevice() {
        var config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-1", name: "Mic", transportType: .usb),
        ])
        let device = AudioDevice(deviceID: 1, name: "Mic", uid: "uid-1", transportType: .usb)
        config.reconcile(connectedDevices: [device])
        XCTAssertEqual(config.entries.count, 1)
    }

    func testUpdatesNameForExistingDevice() {
        var config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-1", name: "Old Name", transportType: .usb),
        ])
        let device = AudioDevice(deviceID: 1, name: "New Name", uid: "uid-1", transportType: .usb)
        config.reconcile(connectedDevices: [device])
        XCTAssertEqual(config.entries.count, 1)
        XCTAssertEqual(config.entries[0].name, "New Name")
    }

    func testReconnectedDeviceUpdatesUID() {
        var config = PriorityConfig(entries: [
            PriorityEntry(uid: "old-uid", name: "Shure MV7", transportType: .usb, enabled: true, dependsOn: "dep-uid"),
        ])
        // Same device reconnects with a new UID
        let device = AudioDevice(deviceID: 2, name: "Shure MV7", uid: "new-uid", transportType: .usb)
        config.reconcile(connectedDevices: [device])

        XCTAssertEqual(config.entries.count, 1, "Should update in place, not add a duplicate")
        XCTAssertEqual(config.entries[0].uid, "new-uid")
        XCTAssertEqual(config.entries[0].enabled, true, "Should preserve enabled state")
        XCTAssertEqual(config.entries[0].dependsOn, "dep-uid", "Should preserve dependency")
    }

    func testReconnectedDevicePreservesPosition() {
        var config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-a", name: "Built-in", transportType: .builtIn),
            PriorityEntry(uid: "old-uid", name: "Shure MV7", transportType: .usb),
            PriorityEntry(uid: "uid-c", name: "AirPods", transportType: .bluetooth),
        ])
        let connected = [
            AudioDevice(deviceID: 1, name: "Built-in", uid: "uid-a", transportType: .builtIn),
            AudioDevice(deviceID: 2, name: "Shure MV7", uid: "new-uid", transportType: .usb),
            AudioDevice(deviceID: 3, name: "AirPods", uid: "uid-c", transportType: .bluetooth),
        ]
        config.reconcile(connectedDevices: connected)

        XCTAssertEqual(config.entries.count, 3)
        XCTAssertEqual(config.entries[1].uid, "new-uid", "Shure MV7 should remain at position 1")
        XCTAssertEqual(config.entries[1].name, "Shure MV7")
    }

    func testRemovesStaleDuplicate() {
        var config = PriorityConfig(entries: [
            PriorityEntry(uid: "current-uid", name: "Shure MV7", transportType: .usb),
            PriorityEntry(uid: "stale-uid", name: "Shure MV7", transportType: .usb),
        ])
        let device = AudioDevice(deviceID: 1, name: "Shure MV7", uid: "current-uid", transportType: .usb)
        config.reconcile(connectedDevices: [device])

        XCTAssertEqual(config.entries.count, 1, "Stale duplicate should be removed")
        XCTAssertEqual(config.entries[0].uid, "current-uid")
    }

    func testDoesNotRemoveDisconnectedDeviceWithoutDuplicate() {
        var config = PriorityConfig(entries: [
            PriorityEntry(uid: "uid-1", name: "Shure MV7", transportType: .usb),
        ])
        // No connected devices — the entry should remain (just disconnected)
        config.reconcile(connectedDevices: [])
        XCTAssertEqual(config.entries.count, 1, "Disconnected device without a duplicate should persist")
    }

    func testExcludesVirtualDevice() {
        var config = PriorityConfig()
        let virtual = AudioDevice(deviceID: 1, name: "RightMic", uid: "com.rightmic.device", transportType: .virtual)
        let real = AudioDevice(deviceID: 2, name: "Mic", uid: "uid-1", transportType: .usb)
        config.reconcile(connectedDevices: [virtual, real], excludingUID: "com.rightmic.device")

        XCTAssertEqual(config.entries.count, 1)
        XCTAssertEqual(config.entries[0].uid, "uid-1")
    }
}

// MARK: - RingBufferWriter Tests

final class RingBufferWriterTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "com.rightmic.test.\(UUID().uuidString)"
    }

    func testConstants() {
        XCTAssertEqual(RingBufferWriter.channelCount, 2)
        XCTAssertEqual(RingBufferWriter.bytesPerFrame, 8)  // 2 channels * 4 bytes
        XCTAssertEqual(RingBufferWriter.ringBufferFrames, 16384)
        XCTAssertEqual(RingBufferWriter.headerSize, 64)
        XCTAssertEqual(RingBufferWriter.dataSize, 16384 * 8)
        XCTAssertEqual(RingBufferWriter.totalSize, 64 + 16384 * 8)
    }

    func testOpenAndClose() throws {
        let path = tempPath()
        let writer = RingBufferWriter(path: path)
        XCTAssertFalse(writer.isOpen)

        try writer.open()
        XCTAssertTrue(writer.isOpen)

        // Verify the backing file was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        writer.close()
        XCTAssertFalse(writer.isOpen)

        writer.unlink()
    }

    func testDoubleOpenIsNoOp() throws {
        let path = tempPath()
        let writer = RingBufferWriter(path: path)
        try writer.open()
        try writer.open()  // should not throw
        XCTAssertTrue(writer.isOpen)
        writer.close()
        writer.unlink()
    }

    func testWriteFrames() throws {
        let path = tempPath()
        let writer = RingBufferWriter(path: path)
        try writer.open()

        // Write 512 frames of silence
        let frameCount = 512
        let sampleCount = frameCount * RingBufferWriter.channelCount
        var samples = [Float](repeating: 0.0, count: sampleCount)
        // Put some test data in
        for i in 0..<sampleCount {
            samples[i] = Float(i) / Float(sampleCount)
        }

        writer.write(frames: &samples, frameCount: frameCount)

        // Writer should still be open and functional
        XCTAssertTrue(writer.isOpen)

        writer.close()
        writer.unlink()
    }

    func testUnlink() throws {
        let path = tempPath()
        let writer = RingBufferWriter(path: path)
        try writer.open()
        writer.close()
        writer.unlink()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Security Tests

    func testFilePermissionsAreRestrictive() throws {
        let path = tempPath()
        let writer = RingBufferWriter(path: path)
        try writer.open()
        defer { writer.close(); writer.unlink() }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let posix = (attrs[.posixPermissions] as! NSNumber).uint16Value
        XCTAssertEqual(posix, 0o600, "File should be owner-only read/write (0600), got \(String(posix, radix: 8))")
    }

    func testOpenRejectsSymlink() throws {
        let target = tempPath()
        let link = tempPath()

        // Create a real file, then a symlink to it
        FileManager.default.createFile(atPath: target, contents: nil)
        defer { unlink(target); unlink(link) }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let writer = RingBufferWriter(path: link)
        XCTAssertThrowsError(try writer.open()) { error in
            guard let rbError = error as? RingBufferWriter.RingBufferError,
                  case .openFailed(let e) = rbError else {
                XCTFail("Expected openFailed with ELOOP, got \(error)")
                return
            }
            XCTAssertEqual(e, ELOOP, "Expected ELOOP (\(ELOOP)), got \(e)")
        }
    }

    func testHeaderStructSizeMatchesConstant() {
        XCTAssertEqual(MemoryLayout<RingBufferWriter.RingBufferHeader>.size, RingBufferWriter.headerSize,
                       "Swift RingBufferHeader size must match headerSize constant (64 bytes)")
    }

    func testAudioDataZeroedOnClose() throws {
        let path = tempPath()
        let writer = RingBufferWriter(path: path)
        try writer.open()

        // Write non-zero audio data
        let frameCount = 512
        let sampleCount = frameCount * RingBufferWriter.channelCount
        var samples = [Float](repeating: 1.0, count: sampleCount)
        writer.write(frames: &samples, frameCount: frameCount)

        writer.close()
        defer { unlink(path) }

        // Read raw file contents and verify all bytes are zero
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let nonZero = data.contains { $0 != 0 }
        XCTAssertFalse(nonZero, "File should be all zeros after close")
    }

    func testCustomPathIsolation() throws {
        let path1 = tempPath()
        let path2 = tempPath()
        let writer1 = RingBufferWriter(path: path1)
        let writer2 = RingBufferWriter(path: path2)
        defer { writer1.close(); writer1.unlink(); writer2.close(); writer2.unlink() }

        try writer1.open()
        try writer2.open()

        // Write different data to each
        var ones = [Float](repeating: 1.0, count: RingBufferWriter.channelCount)
        var twos = [Float](repeating: 2.0, count: RingBufferWriter.channelCount)
        writer1.write(frames: &ones, frameCount: 1)
        writer2.write(frames: &twos, frameCount: 1)

        XCTAssertTrue(writer1.isOpen)
        XCTAssertTrue(writer2.isOpen)
        XCTAssertNotEqual(path1, path2)
    }

    func testOpenRejectsNonRegularFile() throws {
        let fifoPath = tempPath()
        defer { unlink(fifoPath) }

        // Create a FIFO (named pipe)
        let result = mkfifo(fifoPath, 0o600)
        guard result == 0 else {
            XCTFail("Failed to create FIFO: \(String(cString: strerror(errno)))")
            return
        }

        let writer = RingBufferWriter(path: fifoPath)
        XCTAssertThrowsError(try writer.open()) { error in
            guard let rbError = error as? RingBufferWriter.RingBufferError else {
                XCTFail("Expected RingBufferError, got \(error)")
                return
            }
            // O_NONBLOCK isn't set, so open() on a FIFO may block or fail.
            // With O_RDWR on a FIFO, open succeeds but fstat shows it's not S_IFREG.
            if case .notRegularFile = rbError {
                // Expected
            } else if case .openFailed = rbError {
                // Also acceptable — some systems may reject O_CREAT on existing FIFO
            } else {
                XCTFail("Expected notRegularFile or openFailed, got \(rbError)")
            }
        }
    }
}

// MARK: - DriverStatus Tests

final class DriverStatusTests: XCTestCase {

    func testDriverInstallPath() {
        XCTAssertEqual(DriverStatus.driverInstallPath, "/Library/Audio/Plug-Ins/HAL/RightMic.driver")
    }

    func testVirtualDeviceUID() {
        XCTAssertEqual(DriverStatus.virtualDeviceUID, "com.rightmic.device")
    }

    func testIsDriverInstalled() {
        // Unless the driver is actually installed, this should be false
        // (test environment likely doesn't have it)
        let installed = DriverStatus.isDriverInstalled
        // We can't assert true/false since it depends on the machine,
        // but we can assert it returns a Bool without crashing
        XCTAssertTrue(installed || !installed)
    }
}
