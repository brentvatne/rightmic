import SwiftUI
import RightMicCore

/// The popover shown when clicking the menu bar item.
/// Shows the active device and priority-ordered device list.
struct PopoverView: View {
    @ObservedObject var monitor: DeviceMonitor
    var onConfigure: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            deviceListSection
            Divider()
            controlsSection
        }
        .frame(width: 300)
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RightMic")
                .font(.headline)
            if let resolved = monitor.resolvedDevice {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Active: \(resolved.name)")
                        .font(.system(size: 12, weight: .medium))
                    Text("(\(resolved.transportType.rawValue))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                    Text("No device active")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(monitor.priorityConfig.entries.enumerated()), id: \.element.uid) { index, entry in
                            let isActive = entry.uid == monitor.resolvedDevice?.uid
                            let isAvailable = monitor.isDeviceAvailable(entry.uid)
                            PriorityDeviceRow(
                                entry: entry,
                                position: index + 1,
                                isActive: isActive,
                                isAvailable: isAvailable
                            )
                            if index < monitor.priorityConfig.entries.count - 1 {
                                Divider()
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private var controlsSection: some View {
        HStack {
            Spacer()
            controlButton("Configure", systemImage: "gear") {
                onConfigure()
            }
            Spacer()
            controlButton("Quit", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 9))
            }
            .frame(width: 50)
        }
        .buttonStyle(.borderless)
    }
}

/// A row in the popover's priority list showing position, status, and device info.
struct PriorityDeviceRow: View {
    let entry: PriorityEntry
    let position: Int
    let isActive: Bool
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(position)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .trailing)

            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                if isActive {
                    Text("Active")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                } else if !entry.enabled {
                    Text("Disabled")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else if !isAvailable {
                    Text("Disconnected")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(entry.transportType.rawValue)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .opacity(entry.enabled ? 1.0 : 0.5)
        .contentShape(Rectangle())
    }

    private var dotColor: Color {
        if isActive { return .green }
        if !entry.enabled { return .gray.opacity(0.3) }
        if isAvailable { return .blue.opacity(0.5) }
        return .gray.opacity(0.3)
    }
}
