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

## Offene Punkte
- 64 Frames laufen ohne Overloads und halbieren die Latenz. Default bleibt 128
  (Spezifikation); Umschalten in Phase 4 als Option denkbar.
- Bei Gerätewechsel mit anderer Samplerate resampelt der AVAudioEngine-Mixer
  zur Laufzeit; Neu-Dekodieren der Sample-Tabelle steht aus (Phase 3/4).
- Sample-Tabelle ist nur vor `engine.start()` befüllbar (Phase 3: Pack-Wechsel
  → Engine stoppen, neu laden, starten).
- Keine Realtime-Thread-Policy für Tap-/Trigger-Thread; Latenz dort ~0,1 ms,
  nicht nötig.
- Sporadisches `reenabled=1` in Phase-2-Zwischenläufen gesehen (Grund nicht
  protokolliert, seitdem Zähler getrennt). Kein Event ging verloren.

## Nächster Schritt
Phase 3 — Sound-Packs: Mechvibes-`config.json` parsen (v1 single-file mit
`[start_ms, dauer_ms]`, v2 multi-file), Buffer schneiden und in die
Sample-Tabelle laden, `Scancodes.swift` CGKeyCode → Windows-Scancode,
`--list-packs`, `--diag` zeigt Sample-ID pro Taste. Pack liegt unter `packs/`.
