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
    private let onboarding = OnboardingWindow()
    private let statsWindow = StatsWindow()

    init(state: AppState) {
        self.state = state
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if InstallCheck.isRunningFromDiskImage, InstallCheck.offerMoveToApplications() {
            stderrLine("thock: moved to /Applications, relaunching from there")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            return
        }

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
        let host = NSHostingController(rootView: PopoverView(state: state, showSetup: { [weak self] in
            self?.popover.performClose(nil)
            self?.showOnboarding()
        }, showStats: { [weak self] in
            guard let self = self else { return }
            self.popover.performClose(nil)
            self.statsWindow.show(state: self.state)
        }))
        // Let the popover follow the SwiftUI content height; without this a
        // taller view is clipped at the top.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        state.start()
        state.startStatsTicker()
        if !state.onboarded || !CGPreflightListenEventAccess() {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        stderrLine("thock: showing setup window (onboarded=\(state.onboarded), permission=\(CGPreflightListenEventAccess()))")
        onboarding.show(state: state)
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
            if let view = popover.contentViewController?.view {
                view.layoutSubtreeIfNeeded()
                popover.contentSize = view.fittingSize
            }
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
