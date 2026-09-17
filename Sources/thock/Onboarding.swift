import AppKit
import SwiftUI

/// First-launch window: says where the app lives and walks through the
/// Input Monitoring permission. Shown again whenever the permission is
/// missing at launch.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to thock").font(.title2.bold())
                    Text("Mechanical keyboard sounds for your Mac.")
                        .foregroundColor(.secondary)
                }
            }

            Label {
                Text("thock lives in your **menu bar** — look for the keyboard icon at the top right of the screen. Click it to pick a sound, set the volume, or switch it off.")
            } icon: {
                Image(systemName: "keyboard").frame(width: 22)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.permissionGranted ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(state.permissionGranted ? "Input Monitoring: allowed" : "Input Monitoring: not yet allowed")
                        .font(.headline)
                }
                Text("To hear your keystrokes, macOS has to let thock see them. Nothing you type is stored or sent anywhere — thock only turns key presses into sound.")
                    .fixedSize(horizontal: false, vertical: true)
                if !state.permissionGranted {
                    Text("1. Click the button below.\n2. Turn on the switch next to **thock**.\n3. macOS may offer to quit and reopen thock — accept it.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings › Input Monitoring") {
                        state.openInputMonitoringSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }

            Spacer(minLength: 0)

            HStack {
                if state.permissionGranted {
                    Text(state.status).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(state.permissionGranted ? "Done" : "Later") {
                    if state.permissionGranted { state.onboarded = true }
                    close()
                }
                .keyboardShortcut(state.permissionGranted ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 360)
    }
}

final class OnboardingWindow {
    private var window: NSWindow?

    func show(state: AppState) {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView(state: state) { [weak self] in self?.close() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "thock"
        w.contentViewController = NSHostingController(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }
}
