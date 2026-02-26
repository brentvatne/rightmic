import SwiftUI

/// The view rendered directly in the macOS menu bar via NSHostingView.
/// Shows a microphone icon with a colored status dot.
struct MenuBarView: View {
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 13))
            .foregroundStyle(monitor.isEnabled ? .primary : .secondary)
            .frame(width: 24)
    }
}
