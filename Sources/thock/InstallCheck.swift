import AppKit

/// Running straight from the mounted disk image is the classic first-run
/// mistake: the Input Monitoring grant and the login item would point at a
/// volume that disappears on eject. Offer to move the app to Applications.
enum InstallCheck {
    static var isRunningFromDiskImage: Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") else { return false }
        // A DMG mounts read-only; an external drive does not.
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly ?? false
    }

    /// Returns true if the app relaunched itself from /Applications (caller
    /// should then terminate). False: keep running from where we are.
    static func offerMoveToApplications() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move thock to Applications?"
        alert.informativeText = "thock is running from the disk image. Moving it to your Applications folder makes the permission and “Launch at login” stick."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let fm = FileManager.default
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let destination = URL(fileURLWithPath: "/Applications/thock.app")
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Could not move thock"
            fail.informativeText = "\(error.localizedDescription)\n\nDrag thock.app into Applications yourself, then open it from there."
            fail.runModal()
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in }
        return true
    }
}
