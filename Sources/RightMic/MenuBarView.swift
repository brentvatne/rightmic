import SwiftUI

/// The view rendered directly in the macOS menu bar via NSHostingView.
/// Shows a microphone icon with a colored status dot.
struct MenuBarView: View {
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Circle()
                .fill(monitor.resolvedDevice != nil ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
        }
        .frame(width: 24)
    }
}
