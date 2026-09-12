import AppKit
import Combine
import CoreGraphics
import ServiceManagement

/// Model behind the popover. Owns the audio engine and the key pipeline;
/// all mutations go through `queue`, published state is updated on main.
final class AppState: ObservableObject {
    enum Keys {
        static let pack = "pack"
        static let volume = "volume"
        static let keyUp = "keyup"
    }

    @Published var packs: [Resources.PackEntry] = []
    @Published var selectedPack: String {
        didSet { if selectedPack != oldValue { switchPack(to: selectedPack) } }
    }
    @Published var volume: Float {
        didSet {
            defaults.set(volume, forKey: Keys.volume)
            queue.async { [weak self] in self?.audio?.engine.mainMixerNode.outputVolume = self?.volume ?? 1 }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { if launchAtLogin != oldValue { applyLaunchAtLogin(launchAtLogin) } }
    }
    @Published var keyUpSounds: Bool {
        didSet {
            defaults.set(keyUpSounds, forKey: Keys.keyUp)
            queue.async { [weak self] in self?.pipeline?.keyUpSounds = self?.keyUpSounds ?? true }
        }
    }
    @Published var packHasKeyUp = false
    @Published var permissionGranted = false
    @Published var running = false
    @Published var status = "Startet …"
    @Published var packInfo = ""

    let verbose: Bool
    let bufferFrames: UInt32
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "thock.state")
    private var audio: AudioEngine?
    private var pipeline: Pipeline?
    private var drain: Drain?
    private var stats = DiagStats()
    private var permissionTimer: Timer?
    private var permissionRequested = false

    init(verbose: Bool, bufferFrames: UInt32) {
        self.verbose = verbose
        self.bufferFrames = bufferFrames
        selectedPack = defaults.string(forKey: Keys.pack) ?? "topre-purple-hybrid-pbt"
        let v = defaults.object(forKey: Keys.volume) as? Float
        volume = v ?? 1.0
        launchAtLogin = SMAppService.mainApp.status == .enabled
        keyUpSounds = defaults.object(forKey: Keys.keyUp) as? Bool ?? true
    }

    // MARK: lifecycle

    func start() {
        packs = Resources.packEntries(in: Resources.packsRoot)
        if !packs.contains(where: { $0.id == selectedPack }), let first = packs.first {
            selectedPack = first.id      // triggers switchPack; engine not running yet -> just loads
            return
        }
        checkPermissionAndRun()
    }

    func stop() {
        queue.sync {
            teardown()
        }
    }

    /// Summary for the log when the app exits.
    var summary: String {
        var s = stats.summary()
        if let p = pipeline {
            s += " sounds=\(p.triggerCount) seen=\(p.tap.eventCount) "
                + "dropped=\(p.tapRing.droppedCount + p.logRing.droppedCount) "
                + "reenabled=\(p.tap.reenableCount) (\(p.tap.disableReasons))"
        }
        if let a = audio {
            s += " voices_started=\(a.mixer.voicesStarted) overloads=\(a.overloadCount)"
        }
        return s
    }

    // MARK: permission

    private func checkPermissionAndRun() {
        let granted = CGPreflightListenEventAccess()
        permissionGranted = granted
        if granted {
            if permissionTimer != nil {
                stderrLine("thock: Input Monitoring granted")
            }
            permissionTimer?.invalidate()
            permissionTimer = nil
            run()
            return
        }
        if !permissionRequested {
            permissionRequested = true
            _ = CGRequestListenEventAccess()
        }
        status = "Eingabeüberwachung fehlt — in den Systemeinstellungen für thock einschalten."
        if permissionTimer == nil {
            stderrLine("thock: waiting for Input Monitoring permission (checking every 2 s)")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.checkPermissionAndRun()
            }
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: engine + pipeline

    private func run() {
        let packID = selectedPack
        let packs = self.packs
        queue.async { [self] in
            teardown()
            let selection: PackSelection
            if let entry = packs.first(where: { $0.id == packID }) {
                selection = .directory(entry.directory)
            } else {
                selection = .builtIn(clickPath: Resources.clickURL.path)
            }
            guard let audio = makeAudio(selection, bufferFrames: bufferFrames), let pack = audio.pack else {
                publish(status: "Audio konnte nicht gestartet werden (\(selection.label)).", running: false)
                return
            }
            audio.engine.mainMixerNode.outputVolume = volume
            let pipeline = Pipeline(audio: audio, pack: pack)
            pipeline.keyUpSounds = keyUpSounds
            let stats = DiagStats()
            let verbose = self.verbose
            let drain = Drain(ring: pipeline.logRing) { e in
                stats.record(e)
                if verbose { print(formatLine(e)) }
            }
            do {
                try pipeline.start()
            } catch {
                audio.stop()
                publish(status: "Tastatur-Tap verweigert (\(error)). Eingabeüberwachung prüfen, App neu starten.",
                        running: false)
                stderrLine("thock: tap failed: \(error)")
                return
            }
            drain.start()
            self.audio = audio
            self.pipeline = pipeline
            self.drain = drain
            self.stats = stats
            let info = describe(pack)
            stderrLine("thock: running. \(describe(audio.deviceInfo())) voices=\(VoiceMixer.voiceCount)")
            stderrLine("thock: \(info)")
            let hasKeyUp = pack.hasKeyUp
            publish(status: "Aktiv — \(pack.name)", running: true, packInfo: info)
            DispatchQueue.main.async { self.packHasKeyUp = hasKeyUp }
        }
    }

    /// Must run on `queue`.
    private func teardown() {
        pipeline?.stop()
        drain?.stop()
        audio?.stop()
        pipeline = nil
        drain = nil
        audio = nil
    }

    private func switchPack(to id: String) {
        defaults.set(id, forKey: Keys.pack)
        guard permissionGranted else {
            checkPermissionAndRun()
            return
        }
        status = "Lade \(id) …"
        run()
    }

    private func publish(status: String, running: Bool, packInfo: String? = nil) {
        DispatchQueue.main.async {
            self.status = status
            self.running = running
            if let p = packInfo { self.packInfo = p }
        }
    }

    // MARK: launch at login

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            stderrLine("thock: launch at login \(enabled ? "registered" : "unregistered"), status=\(SMAppService.mainApp.status.rawValue)")
        } catch {
            stderrLine("thock: launch at login failed: \(error)")
            DispatchQueue.main.async {
                self.launchAtLogin = SMAppService.mainApp.status == .enabled
                self.status = "Anmeldeobjekt fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}
