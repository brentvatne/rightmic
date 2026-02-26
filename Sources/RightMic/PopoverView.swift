import SwiftUI
import RightMicCore

/// The popover shown when clicking the menu bar item.
/// Shows the active device and priority-ordered device list.
struct PopoverView: View {
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            if !DriverStatus.isVirtualDeviceAvailable {
                driverWarningSection
            }
            Divider()
            deviceListSection
        }
        .frame(width: 300)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Text("RightMic")
                .font(.headline)
            if monitor.isWarming {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Spacer()
            Toggle("", isOn: $monitor.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var driverWarningSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 11))
            Text("RightMic driver not installed")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.08))
    }

    private var deviceListSection: some View {
        Group {
            if monitor.priorityConfig.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.number")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No priority devices configured")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Click Configure to set up your device list.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                List {
                    ForEach(Array(monitor.priorityConfig.entries.enumerated()), id: \.element.uid) { index, entry in
                        let isActive = monitor.isEnabled && entry.uid == monitor.resolvedDevice?.uid
                        let isAvailable = monitor.isDeviceAvailable(entry.uid)
                        let isSilent = monitor.silentDeviceUIDs.contains(entry.uid)
                        PriorityDeviceRow(
                            entry: entry,
                            position: index + 1,
                            isActive: isActive,
                            isAvailable: isAvailable,
                            isSilent: isSilent,
                            isLast: index == monitor.priorityConfig.entries.count - 1
                        )
                        .contextMenu {
                            Button(entry.enabled ? "Disable" : "Enable") {
                                monitor.priorityConfig.entries[index].enabled.toggle()
                            }
                            if monitor.forcedDeviceUID == entry.uid {
                                Button("Unforce") {
                                    monitor.unforceDevice()
                                }
                            } else if isAvailable && entry.enabled {
                                Button("Force") {
                                    monitor.forceDevice(entry.uid)
                                }
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    }
                    .onMove { source, destination in
                        monitor.priorityConfig.entries.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 300)
                .opacity(monitor.isEnabled ? 1.0 : 0.5)
            }
        }
    }


}

/// A row in the popover's priority list showing position, status, and device info.
struct PriorityDeviceRow: View {
    let entry: PriorityEntry
    let position: Int
    let isActive: Bool
    let isAvailable: Bool
    var isSilent: Bool = false
    var isLast: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.name)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .lineLimit(1)

            Spacer()

            if let statusText {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
            }

            statusDot
        }
        .padding(.vertical, 8)
        .opacity(!entry.enabled ? 0.5 : isActive ? 1.0 : 0.7)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().opacity(0.5)
            }
        }
    }

    private var statusText: String? {
        if isActive { return "Active" }
        if !entry.enabled { return "Disabled" }
        if isSilent { return "Silent" }
        if !isAvailable { return "Disconnected" }
        return nil
    }

    private var statusColor: Color { .secondary }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    private var dotColor: Color {
        if isActive { return .green }
        if !entry.enabled { return .primary }
        if !isAvailable { return .primary }
        if isSilent { return .orange }
        if isAvailable { return .blue.opacity(0.5) }
        return .gray.opacity(0.3)
    }
}
