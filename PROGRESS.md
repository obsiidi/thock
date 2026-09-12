# PROGRESS

## Stand
- Toolchain: Swift 6.3.3 (Command Line Tools, kein Xcode), macOS 26.6, Apple M5.
- SPM-Paket, tools-version 5.9 (Swift-5-Sprachmodus), Plattform macOS 13.
- Targets: `CAtomics` (C-Shim, 4 Acquire/Release-Atomics) und `thock` (Executable).
- `swift build` debug + release: 0 Warnungen.
- Ausgabegerät beim Entwickler: "MacBook Pro Speakers", **44.1 kHz**, io_frames=512,
  presentation_ms=1.25.

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

## Offene Punkte
- Ein Player-Node: schnelles Tippen retriggert (`.interrupts`) statt zu
  überlappen → Voice-Pool in Phase 2.
- Bei Gerätewechsel mit anderer Samplerate resampelt der Mixer zur Laufzeit;
  Neu-Dekodieren der Buffer bei Config-Change steht aus (Phase 2/4).
- `render_us` nutzt `AVAudioTime.hostTime` des Mixer-Taps; Genauigkeit
  ungeprüft, nur informativ.
- Keine Realtime-Thread-Policy für Tap-/Trigger-Thread.

## Nächster Schritt
Phase 2 — Audio-Engine: Pool aus 16 `AVAudioPlayerNode` im Round-Robin,
Pitch-Jitter ±3 % über `playbackRate` (AVAudioUnitVarispeed oder
`AVAudioUnitTimePitch`), `kAudioDevicePropertyBufferFrameSize` = 128,
`--selftest --burst 20` (20 Anschläge in 200 ms): 20 Voices, 0 Dropouts,
p95-Latenz < 8 ms.
