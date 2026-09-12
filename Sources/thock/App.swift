import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Menu bar app: status item + transient popover hosting `PopoverView`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var signalSources: [DispatchSourceSignal] = []
    private var enabledObserver: AnyCancellable?

    init(state: AppState) {
        self.state = state
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "thock")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover)
        }

        // Dim the icon while sounds are switched off.
        enabledObserver = state.$enabled.sink { [weak self] enabled in
            self?.statusItem.button?.appearsDisabled = !enabled
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state))

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        state.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.stop()
        stderrLine("thock: stopped. \(state.summary)")
        fflush(stdout)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

/// Runs the menu bar app; never returns.
func runApp(verbose: Bool, bufferFrames: UInt32) -> Never {
    if let id = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
        stderrLine("thock: already running")
        exit(0)
    }
    let app = NSApplication.shared
    let state = AppState(verbose: verbose, bufferFrames: bufferFrames)
    let delegate = AppDelegate(state: state)
    app.delegate = delegate
    app.run()
    exit(0)
}

/// CLI access to the login item, for diagnostics: `--autostart on|off|status`.
func runAutostart(_ arg: String) -> Int32 {
    guard Bundle.main.bundleIdentifier != nil else {
        stderrLine("thock: --autostart only works from inside thock.app")
        return 64
    }
    func describeStatus() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(SMAppService.mainApp.status.rawValue))"
        }
    }
    do {
        switch arg {
        case "on": try SMAppService.mainApp.register()
        case "off": try SMAppService.mainApp.unregister()
        default: break
        }
    } catch {
        print("autostart: \(arg) failed: \(error)")
        return 1
    }
    print("autostart: \(describeStatus())")
    return 0
}
