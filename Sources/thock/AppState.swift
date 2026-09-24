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
        static let enabled = "enabled"
        static let velocity = "velocity"
        static let sensitivity = "sensitivity"
        static let onboarded = "onboarded"
        static let keepStats = "keepStats"
        static let pointerSounds = "pointerSounds"
        static let scrollTicks = "scrollTicks"
        static let mouseSet = "mouseSet"
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
    /// Sounds on/off without quitting; the tap keeps running.
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            queue.async { [weak self] in self?.pipeline?.muted = !(self?.enabled ?? true) }
        }
    }
    /// Velocity from the accelerometer (only meaningful when a sensor exists).
    @Published var velocityEnabled: Bool {
        didSet {
            defaults.set(velocityEnabled, forKey: Keys.velocity)
            queue.async { [weak self] in self?.pipeline?.velocity.enabled = self?.velocityEnabled ?? true }
        }
    }
    /// Slider 0…1 → sensitivity 0.3…3 (log scale, 0.5 ≈ 1).
    @Published var sensitivitySlider: Double {
        didSet {
            defaults.set(sensitivitySlider, forKey: Keys.sensitivity)
            let value = Float(0.3 * pow(10, sensitivitySlider))
            queue.async { [weak self] in self?.pipeline?.velocity.sensitivity = value }
        }
    }
    let sensorAvailable = MotionSensor.isAvailable()
    @Published var sensorStatus = ""
    @Published var permissionGranted = false
    @Published var running = false
    @Published var status = "Starting…"
    @Published var packInfo = ""
    @Published var update: UpdateChecker.Update?
    var onboarded: Bool {
        get { defaults.bool(forKey: Keys.onboarded) }
        set { defaults.set(newValue, forKey: Keys.onboarded) }
    }
    var version: String { UpdateChecker.currentVersion }

    /// Local typing statistics (counts only), fed from the drain thread.
    let typing = TypingStats()
    @Published var keepStats: Bool {
        didSet {
            defaults.set(keepStats, forKey: Keys.keepStats)
            typing.enabled = keepStats
        }
    }
    @Published var todayLine = ""

    /// Trackpad / mouse click sounds and scroll ticks.
    @Published var pointerSounds: Bool {
        didSet {
            defaults.set(pointerSounds, forKey: Keys.pointerSounds)
            queue.async { [weak self] in self?.pipeline?.pointerSounds = self?.pointerSounds ?? true }
        }
    }
    @Published var scrollTicks: Bool {
        didSet {
            defaults.set(scrollTicks, forKey: Keys.scrollTicks)
            queue.async { [weak self] in self?.pipeline?.scrollTicks = self?.scrollTicks ?? false }
        }
    }
    @Published var mouseSets: [Resources.MouseEntry] = []
    @Published var mouseSetID: String {
        didSet {
            guard mouseSetID != oldValue else { return }
            defaults.set(mouseSetID, forKey: Keys.mouseSet)
            if permissionGranted { run() }
        }
    }
    private var statsTimer: Timer?

    let verbose: Bool
    let bufferFrames: UInt32
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "thock.state")
    private var audio: AudioEngine?
    private var pipeline: Pipeline?
    private var drain: Drain?
    private var motion: MotionSensor?
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
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        velocityEnabled = defaults.object(forKey: Keys.velocity) as? Bool ?? true
        sensitivitySlider = defaults.object(forKey: Keys.sensitivity) as? Double ?? 0.5
        keepStats = defaults.object(forKey: Keys.keepStats) as? Bool ?? true
        pointerSounds = defaults.object(forKey: Keys.pointerSounds) as? Bool ?? true
        scrollTicks = defaults.object(forKey: Keys.scrollTicks) as? Bool ?? false
        mouseSetID = defaults.string(forKey: Keys.mouseSet) ?? "mx-master-3s"
        typing.enabled = keepStats
        typing.startAutosave()
    }

    /// Refreshes the one-line summary shown in the popover.
    func refreshTodayLine() {
        todayLine = keepStats ? StatsFormat.todayLine(typing.summary()) : ""
    }

    // MARK: lifecycle

    func start() {
        mouseSets = Resources.mouseEntries()
        reloadPacks()
        if !packs.contains(where: { $0.id == selectedPack }), let first = packs.first {
            selectedPack = first.id      // triggers switchPack; engine not running yet -> just loads
        } else {
            checkPermissionAndRun()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            UpdateChecker.check { update in
                guard let u = update else { return }
                DispatchQueue.main.async { self.update = u }
            }
        }
    }

    func startStatsTicker() {
        refreshTodayLine()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshTodayLine()
        }
    }

    func reloadPacks() {
        packs = Resources.allPackEntries()
        let user = Resources.packEntries(in: Resources.userPacksRoot).count
        stderrLine("thock: packs=\(packs.count) (imported: \(user)) in \(Resources.userPacksRoot.path)")
    }

    // MARK: pack import

    /// Copies a Mechvibes pack folder into the user packs directory, then
    /// selects it. Errors land in `status`.
    func importPack(from source: URL) {
        let fm = FileManager.default
        let config = source.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: config.path) else {
            status = "Not a sound pack: no config.json in \(source.lastPathComponent)."
            return
        }
        // Validate by loading it into a throwaway engine before copying.
        guard let probe = makeAudio(.directory(source), bufferFrames: bufferFrames, start: false), probe.pack != nil else {
            status = "Could not load \(source.lastPathComponent) — see the log for details."
            return
        }
        let root = Resources.userPacksRoot
        let destination = root.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
        } catch {
            status = "Import failed: \(error.localizedDescription)"
            return
        }
        reloadPacks()
        selectedPack = destination.lastPathComponent
    }

    func chooseAndImportPack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Mechvibes sound pack folder (it contains a config.json)."
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            importPack(from: url)
        }
    }

    func revealPacksFolder() {
        let root = Resources.userPacksRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func openFeedback() {
        if let url = URL(string: "https://github.com/\(UpdateChecker.repository)/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        queue.sync {
            teardownAll()
        }
        typing.flush()
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
        if let m = motion {
            s += " motion_reports=\(m.reportCount) gaps=\(m.gapCount)"
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
        status = "Input Monitoring is not allowed yet — turn it on for thock in System Settings."
        if permissionTimer == nil {
            stderrLine("thock: waiting for Input Monitoring permission (checking every 2 s)")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.checkPermissionAndRun()
            }
        }
    }

    func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
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
        let mouseDir = (mouseSets.first { $0.id == mouseSetID } ?? mouseSets.first)?.directory
        queue.async { [self] in
            teardown()
            let selection: PackSelection
            if let entry = packs.first(where: { $0.id == packID }) {
                selection = .directory(entry.directory)
            } else {
                selection = .builtIn(clickPath: Resources.clickURL.path)
            }
            guard let audio = makeAudio(selection, bufferFrames: bufferFrames, mouse: mouseDir), let pack = audio.pack else {
                publish(status: "Audio could not start (\(selection.label)).", running: false)
                return
            }
            audio.engine.mainMixerNode.outputVolume = volume
            var sensorText = "No motion sensor in this Mac — fixed loudness."
            if sensorAvailable {
                if motion == nil {
                    let m = MotionSensor()
                    do {
                        try m.start()
                        motion = m
                    } catch {
                        stderrLine("thock: accelerometer start failed: \(error)")
                    }
                }
                sensorText = motion != nil ? "Motion sensor active." : "Sensor present but not readable — fixed loudness."
            }
            let pipeline = Pipeline(audio: audio, pack: pack, motion: motion)
            pipeline.keyUpSounds = keyUpSounds
            pipeline.pointerSounds = pointerSounds
            pipeline.scrollTicks = scrollTicks
            pipeline.muted = !enabled
            pipeline.velocity.enabled = velocityEnabled
            pipeline.velocity.sensitivity = Float(0.3 * pow(10, sensitivitySlider))
            let stats = DiagStats()
            let verbose = self.verbose
            let typing = self.typing
            let drain = Drain(ring: pipeline.logRing) { e in
                stats.record(e)
                typing.record(e)
                if verbose { print(formatLine(e)) }
            }
            do {
                try pipeline.start()
            } catch {
                audio.stop()
                publish(status: "Keyboard access was refused (\(error)). Check Input Monitoring and restart thock.",
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
            stderrLine("thock: mouse sounds: \(audio.mouse?.name ?? "none") clicks=\(pointerSounds) scroll=\(scrollTicks)")
            let hasKeyUp = pack.hasKeyUp
            stderrLine("thock: velocity " + (motion != nil ? "on (accelerometer)" : "off (no sensor)"))
            publish(status: "Active — \(pack.name)", running: true, packInfo: info)
            DispatchQueue.main.async {
                self.packHasKeyUp = hasKeyUp
                self.sensorStatus = sensorText
            }
        }
    }

    /// Must run on `queue`. The sensor stays open across pack switches.
    private func teardown() {
        pipeline?.stop()
        drain?.stop()
        audio?.stop()
        pipeline = nil
        drain = nil
        audio = nil
    }

    private func teardownAll() {
        teardown()
        motion?.stop()
        motion = nil
    }

    private func switchPack(to id: String) {
        defaults.set(id, forKey: Keys.pack)
        guard permissionGranted else {
            checkPermissionAndRun()
            return
        }
        status = "Loading \(id)…"
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
                self.status = "Launch at login failed: \(error.localizedDescription)"
            }
        }
    }
}
