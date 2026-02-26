import SwiftUI
import ServiceManagement
import RightMicCore

/// Settings window with drag-to-reorder priority list, add/remove devices, and options.
struct SettingsView: View {
    @ObservedObject var monitor: DeviceMonitor
    @State private var launchAtLogin = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            priorityListSection
            Divider()
            addDeviceSection
            Divider()
            optionsSection
        }
        .frame(minWidth: 450, maxWidth: 450, minHeight: 350)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Priority List")
                .font(.headline)
            Text("Drag to reorder. The highest-priority connected device will be used.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: - Priority List

    private var priorityListSection: some View {
        Group {
            if monitor.priorityConfig.entries.isEmpty {
                VStack(spacing: 8) {
                    Text("No devices in priority list")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Add devices using the button below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                List {
                    ForEach($monitor.priorityConfig.entries) { $entry in
                        PriorityRowView(
                            entry: $entry,
                            isAvailable: monitor.isDeviceAvailable(entry.uid)
                        )
                    }
                    .onMove { source, destination in
                        monitor.priorityConfig.entries.move(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { indices in
                        monitor.priorityConfig.entries.remove(atOffsets: indices)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 150, maxHeight: 350)
            }
        }
    }

    // MARK: - Add Device

    private var addDeviceSection: some View {
        HStack {
            let available = monitor.availableToAdd
            if available.isEmpty {
                Text("All connected devices are in the list")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Menu {
                    ForEach(available) { device in
                        Button {
                            monitor.addToPriority(device)
                        } label: {
                            Text("\(device.name) — \(device.transportType.rawValue)")
                        }
                    }
                } label: {
                    Label("Add Device", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Options

    private var optionsSection: some View {
        HStack {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }
            Spacer()
        }
        .padding()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[RightMic] Failed to update login item: \(error)")
        }
    }
}

/// A single row in the priority list.
struct PriorityRowView: View {
    @Binding var entry: PriorityEntry
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $entry.enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Circle()
                .fill(isAvailable ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.transportType.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if !isAvailable {
                        Text("(disconnected)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .opacity(entry.enabled ? 1.0 : 0.5)
    }
}
