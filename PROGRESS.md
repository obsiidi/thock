# PROGRESS

## Stand
- Toolchain: Swift 6.3.3 (Command Line Tools, kein Xcode), macOS 26.6, Apple M5.
- SPM-Paket, tools-version 5.9 (Swift-5-Sprachmodus), Plattform macOS 13.
- Targets: `CAtomics` (C-Shim, 4 Acquire/Release-Atomics) und `thock` (Executable).
- `swift build` debug + release: 0 Warnungen.

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

## Offene Punkte
- Autorepeat wird nur geflaggt (`rep=1`), nicht gefiltert. Entscheidung in Phase 1.
- `flagsChanged` liefert nur den Rohwert der Flags; Down/Up für Modifier wird
  erst abgeleitet, wenn Soundpacks Modifier-Sounds brauchen (Phase 3).
- Tap-Thread läuft mit QoS userInteractive, keine Realtime-Policy. Bei Bedarf
  in Phase 2 nachziehen.

## Nächster Schritt
Phase 1 — Ton am Anschlag: Klick-WAV per Skript generieren (Rauschimpuls,
Bandpass ~3 kHz, 6 ms Decay), `AVAudioEngine` + `AVAudioPlayerNode`,
`--selftest` misst Latenz CGEvent-Timestamp → `scheduleBuffer`, Median < 5 ms.
