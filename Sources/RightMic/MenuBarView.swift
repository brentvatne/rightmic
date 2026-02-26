import SwiftUI

/// The view rendered directly in the macOS menu bar via NSHostingView.
/// Shows a microphone icon with a colored status dot.
struct MenuBarView: View {
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: monitor.isEnabled ? "arrow.triangle.branch" : "arrow.triangle.branch")
                .font(.system(size: 13))
                .foregroundStyle(monitor.isEnabled ? .primary : .secondary)
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        }
        .frame(width: 24)
    }

    private var statusColor: Color {
        if !monitor.isEnabled { return .secondary }
        return monitor.resolvedDevice != nil ? .green : .orange
    }
}
