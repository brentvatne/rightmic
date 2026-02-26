import AppKit
import Combine
import RightMicCore
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = DeviceMonitor()
    private var audioRouter: AudioRouter?
    private var hostingView: PassthroughHostingView<MenuBarView>!
    private var eventMonitor: Any?
    private var rightClickMonitor: Any?
    private var settingsWindow: NSWindow?
    private var manageWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[RightMic] applicationDidFinishLaunching")
        cleanupStaleSharedMemory()
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        setupRightClickMenu()
        requestPermission()

        // Start audio routing (captures from resolved device → ring buffer → HAL driver)
        audioRouter = AudioRouter(monitor: monitor)
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioRouter?.shutdown()
    }

    // MARK: - Stale Shared Memory Cleanup

    /// Remove any leftover shared memory file from a previous crash.
    /// Zeroes the contents before unlinking to prevent residual audio leakage.
    private func cleanupStaleSharedMemory() {
        let path = RingBufferWriter.sharedMemoryPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        NSLog("[RightMic] Found stale shared memory file, cleaning up")
        let fd = Darwin.open(path, O_RDWR | O_NOFOLLOW)
        if fd >= 0 {
            var st = stat()
            if fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_size > 0 {
                let size = Int(st.st_size)
                let ptr = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
                if ptr != MAP_FAILED {
                    memset(ptr, 0, size)
                    msync(ptr, size, MS_SYNC)
                    munmap(ptr, size)
                }
            }
            Darwin.close(fd)
        }
        unlink(path)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else { return }

        let menuBarView = MenuBarView(monitor: monitor)
        hostingView = PassthroughHostingView(rootView: menuBarView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 24, height: button.bounds.height)

        button.addSubview(hostingView)
        button.frame = hostingView.frame
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let popoverView = PopoverContentView(monitor: monitor)
        popover.contentViewController = NSHostingController(rootView: popoverView)
    }

    private func updatePopoverSize() {
        let entryCount = monitor.priorityConfig.entries.count
        let padding: CGFloat = 12
        let listHeight: CGFloat = entryCount > 0
            ? CGFloat(entryCount) * 32
            : 100
        popover.contentSize = NSSize(width: 300, height: listHeight + padding)
    }

    // MARK: - Settings Window

    func openSettings() {
        if popover.isShown {
            popover.performClose(nil)
        }

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(monitor: monitor)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "RightMic Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 500))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            updatePopoverSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Right-Click Menu

    private func setupRightClickMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem.button,
                  event.window == button.window else { return event }

            let locationInButton = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(locationInButton) else { return event }

            let menu = NSMenu()

            let enableItem = NSMenuItem(title: "Enabled", action: #selector(self.toggleEnabled(_:)), keyEquivalent: "")
            enableItem.target = self
            enableItem.state = self.monitor.isEnabled ? .on : .off
            menu.addItem(enableItem)

            menu.addItem(.separator())

            let manageItem = NSMenuItem(title: "Manage devices…", action: #selector(self.openManageDevices), keyEquivalent: "")
            manageItem.target = self
            menu.addItem(manageItem)

            let launchItem = NSMenuItem(title: "Launch at login", action: #selector(self.toggleLaunchAtLogin(_:)), keyEquivalent: "")
            launchItem.target = self
            launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(launchItem)

            menu.addItem(.separator())

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let versionItem = NSMenuItem(title: "v\(version)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)

            menu.addItem(NSMenuItem(title: "Quit", action: #selector(self.quitApp), keyEquivalent: "q"))
            menu.items.forEach { $0.target = self }
            self.statusItem.menu = menu
            button.performClick(nil)
            self.statusItem.menu = nil
            return nil
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        monitor.isEnabled.toggle()
    }

    @objc private func openManageDevices() {
        if popover.isShown { popover.performClose(nil) }

        if let window = manageWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ManageDevicesView(monitor: monitor)
        let controller = NSHostingController(rootView: view)
        let fittingSize = controller.sizeThatFits(in: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        let window = NSWindow(contentViewController: controller)
        window.title = "Manage Devices"
        window.styleMask = [.titled, .closable]
        window.setContentSize(fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        manageWindow = window
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[RightMic] Failed to update login item: \(error)")
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Event Monitor

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    // MARK: - Permission

    private func requestPermission() {
        monitor.requestPermission { _ in }
    }
}

/// NSHostingView subclass that passes all mouse events through to the
/// superview (the status item button), so the button action still fires.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Wrapper that decides between showing the permission view or the main popover.
struct PopoverContentView: View {
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        if monitor.permissionGranted {
            PopoverView(monitor: monitor)
        } else {
            PermissionView {
                monitor.requestPermission { _ in }
            }
        }
    }
}
