# PROGRESS

## Stand
- Toolchain: Swift 6.3.3 (Command Line Tools, kein Xcode), macOS 26.6, Apple M5.
- SPM-Paket, tools-version 5.9 (Swift-5-Sprachmodus), Plattform macOS 13.
- Targets: `CAtomics` (C-Shim, 4 Acquire/Release-Atomics) und `thock` (Executable).
- `swift build` debug + release: 0 Warnungen.
- Ausgabegerät beim Entwickler: "MacBook Pro Speakers", **48 kHz** (Phase 1 hatte
  fälschlich 44.1 kHz gemeldet — `mainMixerNode.outputFormat` liefert vor `prepare()`
  einen Default), Puffer-Range 15…4096 Frames, presentation_ms=1.25.

## Phase 0 — Tastenerfassung ✅
Abgenommen am 2026-09-12.

- `KeyTap.swift`: `CGEventTap` `.listenOnly` an `.cgSessionEventTap`, keyDown/keyUp/
  flagsChanged, eigener Thread (QoS userInteractive, eigener RunLoop).
  Re-Enable bei `.tapDisabledByTimeout`/`.tapDisabledByUserInput` im Callback,
  zusätzlich 5-s-Watchdog-Timer (`tapIsEnabled`). Callback allokations-, lock-
  und logfrei: nur Feldzugriffe + Ring-Push.
- `EventRing.swift`: SPSC-Ring, 4096 Slots, POD-Struct `KeyEvent`, Drops gezählt.
- `Diagnostics.swift`: Drain-Thread (pollt 10 ms), `--diag [--all]`,
  `--selftest-tap [--count N] [--idle S]`, Freigabe-Preflight.
- Exit-Codes: 0 ok · 1 Selftest fehlgeschlagen · 2 keine Freigabe · 3 Tap nicht
  erstellbar · 64 Argumentfehler.

Messwerte (`--selftest-tap --count 20 --idle 60`, Debug-Build):
```
keyDowns=40/40 keyUps=40/40 seqGaps=0 dropped=0 reenabled=0
age_us min=45 median=76 max=134   (CGEvent-Timestamp → Callback-Eintritt)
```

Befunde:
- `CGEvent.timestamp` ist **Nanosekunden** seit Boot (nicht mach-Ticks).
  `mach_timebase_info` = 125/3. Umrechnung in `Clock.ticksToNanos`.
- Synthetische Test-Taste: F20 (keyCode 0x5A), markiert über
  `eventSourceUserData = 0x7404C4` → `syn=1` im Log.
- TCC: Prozesse aus der Claude-Code-Sitzung werden **Claude.app** zugerechnet.
  Claude.app hat Eingabeüberwachung + Bedienungshilfen → Selftests laufen direkt
  in der Sitzung. Terminal.app braucht eigene Freigabe.

## Phase 1 — Ton am Anschlag ✅
Abgenommen am 2026-09-12.

- `Tools/gen-click.swift`: deterministischer Klick (xorshift-Rauschen, RBJ-
  Bandpass 3 kHz Q=2, e^(−t/6 ms), 50 ms, −6 dBFS, 16-bit-Mono-WAV, Header
  handgeschrieben). `swift Tools/gen-click.swift Samples/click.wav [--rate HZ]`.
- `Samples/click.wav` (48 kHz) ist committet.
- `AudioEngine.swift`: `AVAudioEngine` + ein `AVAudioPlayerNode`. Sample wird
  beim Laden per `SampleConverter` ins Mixer-Format gebracht (Rate via
  `AVAudioConverter`, Mono→Stereo per memcpy). `trigger()` =
  `scheduleBuffer(.interrupts)`. Restart bei `AVAudioEngineConfigurationChange`.
  `deviceInfo()` liest Gerätename, `kAudioDevicePropertyBufferFrameSize`,
  `presentationLatency`.
- `Pipeline.swift`: Tap → Ring A → Trigger-Thread (userInteractive, per
  `DispatchSemaphore` geweckt) → `scheduleBuffer` → Ring B → Drain. Tap-Callback
  unverändert allokationsfrei; nur der Trigger-Thread spricht mit AVFoundation.
- CLI: `thock` (Ton, kein Log), `--diag [--all]` (+ `tap_us`, `sched_us`,
  `lat_us`), `--selftest [--count N]`, `--sample PFAD`. Exit 4 = Audio-Setup.
- `--selftest` beweist das Rendern über einen `installTap` am Mixer-Ausgang:
  Flanken still→laut (−40 dBFS, 20 ms Hysterese) = gerenderte Klicks.

Messwerte (`--selftest --count 50`, Debug-Build, 44.1-kHz-Gerät, Resampling 48k→44.1k):
```
keyDowns=50/50 scheduled=50/50 rendered=50/50 dropped=0 mixer_peak=0.505
lat_us    min=107 median=204 p95=294 max=361   (Event → scheduleBuffer)
tap_us    min=83  median=156 p95=186           (Event → Callback)
sched_us  min=23  median=47  p95=130           (Callback → scheduleBuffer)
render_us min=12526 median=20807 p95=22614     (scheduleBuffer → Mixer-Ausgang)
```

Befunde:
- Die Software-Seite ist mit ~0,2 ms irrelevant. Die echte Latenz sitzt im
  Render: ~21 ms bei io_frames=512 (11,6 ms/Puffer @ 44.1k, plus ein Zyklus
  Scheduling). Phase 2 setzt 128 Frames; Ziel render_us < 8 ms.
- Entscheidung: Autorepeat klickt nicht (`Pipeline.clickOnRepeat = false`).
- Modifier (`flagsChanged`) bleiben bis Phase 3 stumm.

## Phase 2 — Audio-Engine ✅
Abgenommen am 2026-09-12.

⚠️ **Architekturabweichung:** Der Voice-Pool ist **kein** Pool aus 16
`AVAudioPlayerNode` mehr, sondern ein eigener Mixer in einem
`AVAudioSourceNode` (`VoiceMixer.swift`). Grund, gemessen: `scheduleBuffer` des
Player-Nodes startete Buffer sporadisch 20–30 ms zu spät — bei 64, 128, 256 und
512 Frames, mit und ohne Varispeed, mit und ohne `.interrupts`, auch mit nur
einem Node. Muster: ein Ausreißer, dann Rampe über ~5 Events zurück auf normal.
Per `.dataRendered`-Callback unabhängig bestätigt. Mit dem Source-Node ist die
Latenz deterministisch (max. ein IO-Puffer + Ausgabe-Offset).

- `VoiceMixer.swift`: `AVAudioSourceNode`, 16 Voices in festem Array hinter
  Raw-Pointern, Sample-Tabelle (max. 512, Phase 3), `CommandRing` (SPSC) vom
  Trigger-Thread in den Render-Block. Pitch = lineare Interpolation mit `rate`.
  Round-Robin; eine Voice wird ohne Fade überschrieben, wenn alle 16 belegt sind.
  `startLog` (SPSC) protokolliert jeden Voice-Start mit Render-Zeitstempel.
- `AudioEngine.swift`: Engine-Format = Hardware-Rate aus
  `outputNode.outputFormat(forBus:)` (nicht Mixer-Format!), IO-Puffer über
  `kAudioDevicePropertyBufferFrameSize` (Default 128, `--io-frames`),
  `kAudioDeviceProcessorOverload`-Listener als Dropout-Zähler.
- `Pipeline.swift`: xorshift-Jitter `rate = 1 ± 0.03` (`--jitter`).
- `KeyTap.swift`: Disable-Gründe getrennt gezählt (timeout / userInput).
- `--selftest [--count N] | --burst N`: Latenz `e2r_us` = Event → Render-Zyklus,
  der die Voice startet (aus `startLog`); extern bestätigt durch Onset-Detektor
  am Mixer-Tap (`agree_us` = 0 im Spaced-Modus) und Energie-Bilanz
  (`energy_ratio` ≈ N Klicks, ±10 %).

Messwerte (Debug-Build, 48 kHz, io_frames=128):
```
spaced 50:  voices_started=50/50 onsets=50/50 energy=47.6/50 overloads=0
            e2r_us min=3839 median=5459 p95=6346 max=6374
burst 20:   voices_started=20/20 energy=18.9/20 overloads=0 mixer_peak=0.59
            e2r_us min=3745 median=5246 p95=6362 max=6362
burst 40:   voices_started=40/40 energy=38.4/40 overloads=0  (Pool überbucht, OK)
io 64:      e2r_us median=3380 p95=3692 (spaced), 3065/3648 (burst), 0 overloads
io 512:     e2r_us median=17634 p95=21477  (Vergleich)
```
Energie liegt ~5 % unter N: lineare Interpolation dämpft bei 3 kHz leicht.

## Phase 3 — Sound-Packs ✅
Abgenommen am 2026-09-12.

- **Sounds:** sieben echte Aufnahmen aus dem Mechvibes-Repo
  (`hainguyents13/mechvibes`, MIT), mit Freigabe des Entwicklers geladen und
  unter `packs/` committet (~12 MB): cherrymx-{blue,brown,red,black}-abs,
  topre-purple-hybrid-pbt (Default), holy-pandas (v2, mit Key-up-Sounds),
  nk-cream (multi-wav).
- **OGG:** `AVAudioFile` dekodiert Vorbis auf diesem macOS (26.6) nativ —
  identisch zu ffmpeg (Peak −9,14 dB, RMS −43,75 dB gegengeprüft). Keine
  Konvertierung nötig. Fallback im Loader: schlägt `.ogg` fehl, wird eine
  gleichnamige `.wav/.flac/.m4a/.mp3` gesucht (ältere macOS).
- `Scancodes.swift`: CGKeyCode → libuiohook-Code (Windows-Set-1-Scancode mit
  0x0E-/0xE0-Präfix), 128er-Array, plus Reihen-Tabelle (v2 `GENERIC_R{0-4}`)
  und Namen. ISO-Taste (kc 10) → 86, `^` (kc 50) → 41. Fn/Medientasten → −1.
- `SoundpackLoader.swift`: config.json tolerant (Slice-Array, Datei, null,
  `"NN-up"`, `soundup`, `{0-4}`-Muster). Single: Datei einmal dekodieren,
  Slices mit 0,5/2 ms Fades kopieren, gleiche Slices dedupliziert. Pack global
  auf −6 dBFS Peak normalisiert. Undefinierte Tasten → Reihen-Generic, sonst
  häufigstes Sample. Sample-Reihenfolge deterministisch (sortierte Codes).
- `Pipeline.swift`: Modifier aus `flagsChanged` (Flag-Bit + Zustand pro Taste,
  CapsLock über Bit-Wechsel), Key-up-Sounds, Lookup über zwei feste
  128er-Tabellen — kein Hashing im Trigger-Thread.
- CLI: `--list-packs [--packs-dir]`, `--pack NAME|PFAD|click`, `--map`,
  `--diag` mit `key= scan= down= sample=`.
- Selftest: Energie-Erwartung berücksichtigt Voice-Stealing (Slice wird
  abgeschnitten, wenn die Voice nach 16 Starts wiederverwendet wird); Toleranz
  ±10 % spaced, ±20 % burst (korrelierte Überlagerung derselben Aufnahme).
  Onset-Detektor nur noch für den Built-in-Klick (echte Aufnahmen haben mehrere
  Transienten pro Slice).

Messwerte (Debug, 128 Frames): alle 7 Packs + Klick `--selftest --burst 20`
PASS, e2r p95 6,2–6,4 ms, 0 Overloads. `--map topre`: Buchstaben 26
verschiedene Slices, Space #56, Enter #39, Backspace #15. holy-pandas:
Shift → GENERIC_R3, Release → release/GENERIC (per `--diag --all` belegt).

## Phase 4 — Menüleisten-App ✅
Abgenommen am 2026-09-12.

- **Bundle ohne Xcode:** `Tools/bundle.sh` → `swift build -c release`,
  `dist/thock.app` (Info.plist aus `Tools/`, `LSUIElement`, Packs + Klick in
  `Resources/`), `codesign`. `dist/` ist gitignored.
- **Signatur:** selbstsigniertes Zertifikat `thock-dev` im Login-Schlüsselbund,
  per `Tools/make-cert.sh` angelegt (openssl + `security import` +
  `add-trusted-cert`, kostenlos). Designated Requirement =
  `identifier "com.mauriceberthold.thock" and certificate leaf = H"d5cd…"` —
  Rebuild-stabil, **bewiesen**: nach Rebuild + Relaunch sofort `running`.
- **TCC-Falle, erlebt:** Ein Eintrag aus der Ad-hoc-Zeit blockiert die signierte
  App still (gemerkter cdhash passt nicht, Schalter an/aus hilft nicht). Lösung:
  `tccutil reset ListenEvent com.mauriceberthold.thock`, App neu starten,
  einmal freigeben. Beim Umschalten in den Systemeinstellungen relauncht macOS
  die App („Beenden und erneut öffnen") — dann ohne Log-Umleitung.
- `App.swift`: `NSStatusItem` (SF-Symbol `keyboard`), `NSPopover .transient`
  mit `NSHostingController`, SIGTERM/SIGINT → sauberes Stoppen mit Summary,
  Single-Instance-Guard. `--autostart on|off|status` als CLI.
- `AppState.swift`: Pack-Liste, Pack-Wechsel (Teardown → neue Engine+Pipeline,
  serialisiert auf eigener Queue), Lautstärke = `mainMixerNode.outputVolume`,
  Loslass-Geräusche-Schalter (atomares Flag im Trigger-Thread), Autostart via
  `SMAppService.mainApp`, Freigabe-Polling alle 2 s. Persistenz in
  `UserDefaults` (`pack`, `volume`, `keyup`).
- `PopoverView.swift`: Dropdown (Pack-Namen aus config.json), Slider,
  Schalter Loslass-Geräusche (ausgegraut, wenn das Pack keine hat), Autostart,
  Statuszeile mit Knopf „Systemeinstellungen öffnen", Beenden.
- `Resources.swift`: Packs/Klick aus dem Bundle oder aus dem cwd (CLI).
- `main.swift`: ohne Argumente GUI, `--headless` alter CLI-Loop, `--verbose`
  loggt in der GUI jeden Anschlag.

Abnahme-Belege:
- `lsappinfo`: `type="UIElement"` — kein Dock-Icon.
- `open --stderr LOG dist/thock.app --args --verbose` + 5 synthetische
  F20-Events → 5× `kd … sample=…` durch die App-Pipeline; Summary bei SIGTERM.
- Sieben Pack-Wechsel per Dropdown im Log, Defaults gespeichert
  (`pack=holy-pandas volume=0.49 keyup=0`).
- `--autostart status` → `enabled` nach Umlegen des Schalters im Popover.
- Loslass-Schalter: an → `ku … sample=11`, aus → `ku … sample=-`.
- Neustart-Beweis (App läuft nach Login) steht beim Entwickler aus.

## MVP-Modus (ab 2026-09-17)
Richtung A: Gratis-Haptyk, Open Source (MIT), null Kosten für Beta/MVP,
Developer ID als offene Tür. Autonom: Selbstprüf-Loop pro Phase, weiter ohne
Rückfrage. Plan: `~/.claude/plans/schreibe-kein-code-bis-curried-valley.md`.

## Phase 5 — Anschlagstärke (Sensor) ✅ (Code), Mess-Abnahme offen
- `Motion.swift`: `AppleSPUHIDDevice` (Usage Page 0xFF00, Usage 3, 22-Byte-
  Reports). **Nicht-offensichtlich:** Reports fließen erst, wenn auf den
  `AppleSPUHIDDriver`-Services `SensorPropertyReportingState=1`,
  `SensorPropertyPowerState=1`, `ReportInterval=1000` gesetzt sind (per
  `IORegistryEntrySetCFProperty`, vor dem Öffnen). Ohne das: Open ok, null
  Reports. Zwei Geräte matchen Usage 3; das mit `MaxInputReportSize == 22`
  ist der Sensor. Gemessen: ~800 Reports/s, 0 Lücken, Rauschen ~0.001 g,
  Zugriff ohne sudo (Eingabeüberwachung reicht).
- Layout: u16 Sequenz @0, x/y/z IOFixed 16.16 @6/10/14, Die-Temperatur @18.
- `MotionRing`: Broadcast-Ring (4096), Konsument scannt Zeitfenster rückwärts.
- `VelocityEstimator`: Peak im Fenster −15…+5 ms um den Keydown, Rauschboden
  ×2 abgezogen, laufendes Maximum (Halbwertszeit 60 s) × Empfindlichkeit →
  Kraft 0…1. Kein Signal über dem Rauschen (externe Tastatur, synthetisch) →
  neutrale Kraft 0,5. Kraft → Gain −15…0 dB (f^0.7), One-Pole-Tiefpass
  1,5–20 kHz, ±1,5 % Rate. Key-up-Sounds fest bei 0,5.
- `VoiceMixer`: `gain`, `lowpass` pro Voice (One-Pole im Render-Loop).
- Popover: Schalter „Anschlagstärke", Slider leicht…fest (0,3…3, log),
  Sensor-Statuszeile. Persistenz `velocity`, `sensitivity`.
- CLI: `--diag-motion` (pro Anschlag Peak vor/nach Event, Versatz des
  Maximums, Kraft — **keine Tastencodes**), `--motion-selftest` (10× leicht,
  10× fest → PASS bei Median-Faktor ≥ 2 und getrennten Quartilen),
  `--no-velocity`.
- Offen: Timing-Fenster und Kraft-Skala mit echten Anschlägen prüfen
  (`--diag-motion` läuft im Hintergrund und sammelt), `--motion-selftest`
  braucht den Entwickler.

## Offene Punkte
- Sensor-Report-Intervall bleibt nach Stop auf 1000 µs (absichtlich, wegen
  paralleler thock-Prozesse).
- Pack-Wechsel zur Laufzeit stoppt/startet Engine; Sensor bleibt offen.
- `tapDisabledByUserInput` sporadisch, Re-Enable greift.

## Nächster Schritt
Phase 6 — MVP-UX: Onboarding-Fenster, Icon, Pack-Import, Update-Check,
Universal Build, Feedback-Link.
