# Startprompt für Claude Code

> Kopiere alles ab der Trennlinie in die erste Claude-Code-Sitzung.
> `CLAUDE.md` vorher ins Projektverzeichnis legen.

---

## HARTE REGELN

1. **Das Projekt kostet null Euro.** Keine kostenpflichtigen Dienste, APIs, Abos,
   Pakete, Assets, Lizenzen. Kein Apple Developer Program. Nichts, das ein Konto
   mit Zahlungsmethode verlangt. **Wenn unklar ist, ob etwas Geld kostet, kostet
   es Geld — nicht benutzen, kostenlose Alternative vorschlagen.**
2. Kein `sudo`. Keine Änderungen an Systemeinstellungen oder außerhalb des
   Projektordners.
3. Keine externen Swift-Packages. Nur Apple-Frameworks. Ausnahmen nur nach
   Rückfrage.
4. Vor dem ersten Code jeder Phase: Plan vorlegen, auf mein „los" warten.

## ROLLE

Du baust systemnahe macOS-Software und verifizierst jede Behauptung durch
messbaren Output, nicht durch Hinsehen. Du kannst nichts hören — richte den Code
so ein, dass du ihn trotzdem prüfen kannst.

## WAS GEBAUT WIRD

`thock`: eine macOS-Menüleisten-App, die beim Tippen auf der eingebauten
MacBook-Tastatur mechanische Tastaturgeräusche abspielt. Systemweit, latenzarm,
mit austauschbaren Sound-Packs. Rein privat, kein Vertrieb.

## BEREITS ENTSCHIEDEN — nicht neu erfinden

- Swift Package Manager Executable. Kein Xcode-Projekt vor Phase 4.
- Tastenerfassung: `CGEventTap`, `.listenOnly`, an `.cgSessionEventTap`.
- Audio: `AVAudioEngine` + Pool aus 16 `AVAudioPlayerNode` im Round-Robin.
  Samples beim Start als `AVAudioPCMBuffer` im Engine-Format vordecodieren.
  Hardware-Puffer über `kAudioDevicePropertyBufferFrameSize` auf 128 Frames.
- Sound-Packs: Mechvibes-`config.json`-Format (v1 single-file mit
  `[start_ms, dauer_ms]`, v2 multi-file).
- Dev-Loop Phase 0–3: CLI aus dem Terminal, erbt die Bedienungshilfen-Freigabe.

## PHASEN

Eine Phase pro Durchlauf. Am Ende: Commit, `PROGRESS.md` aktualisieren, kurzer
Bericht, Stopp.

**Phase 0 — Tastenerfassung.**
Event-Tap aufbauen, pro Anschlag eine Zeile mit keyCode und Timestamp drucken.
*Abnahme:* 20 Anschläge erzeugen 20 Zeilen, keine Dopplung, kein Aussetzer nach
60 s Leerlauf.

**Phase 1 — Ton am Anschlag.**
Ein Klick-WAV bei jedem Keydown. Das Test-Sample generierst du selbst per Skript
(kurzer Rauschimpuls, Bandpass ~3 kHz, 6 ms Decay) — es wird nichts
heruntergeladen.
*Abnahme:* `--selftest` misst Latenz von CGEvent-Timestamp bis `scheduleBuffer`,
Median unter 5 ms.

**Phase 2 — Audio-Engine.**
Voice-Pool, Preload, Round-Robin, Pitch-Jitter ±3 % über `playbackRate`,
Puffergröße setzen. Render-Pfad allokationsfrei.
*Abnahme:* `--selftest --burst 20` (20 Anschläge in 200 ms) spielt 20 Voices,
null Dropouts, p95-Latenz unter 8 ms.

**Phase 3 — Sound-Packs.**
Mechvibes-Config parsen, Buffer schneiden, `Scancodes.swift` mit der
Übersetzungstabelle CGKeyCode → Windows-Scancode. Ich lege einen echten Pack
unter `packs/` ab — du lädst keine Dateien aus dem Netz.
*Abnahme:* `--list-packs` zeigt den Pack, `--diag` belegt, dass Space, Enter und
Backspace andere Sample-IDs treffen als Buchstaben.

**Phase 4 — Menüleisten-App.**
.app-Bundle, `NSStatusItem`, `LSUIElement = true`, SwiftUI-Popover für
Lautstärke und Pack-Auswahl, Autostart über `SMAppService.mainApp.register()`.
Signierung mit einem selbstsignierten Zertifikat aus der Schlüsselbundverwaltung
(kostenlos), damit die Freigabe Rebuilds überlebt.
*Abnahme:* App startet ohne Dock-Icon, läuft nach Neustart, Ton kommt.

**Phase 5 — Anschlagstärke (nur wenn der Sensor existiert).**
Führe zuerst aus:
```
sysctl -n machdep.cpu.brand_string
ioreg -l -w0 | grep -c AppleSPUHIDDevice
```
Zahl > 0 → der SPU-Accelerometer ist vorhanden, Phase 5 läuft.
Zahl = 0 → Phase 5 entfällt, stattdessen Anschlagstärke aus dem Intervall
zwischen zwei Keydowns plus der Haltedauer keydown→keyup schätzen. Nicht
diskutieren, einfach die passende Variante bauen.

Sensorzugriff: `AppleSPUHIDDevice`, Vendor Usage Page `0xFF00`, Usage 3 =
Accelerometer. `IOHIDDeviceCreate` plus `IOHIDDeviceRegisterInputReportCallback`,
22-Byte-Reports, x/y/z als int32 little-endian bei Byte-Offset 6/10/14, Wert
durch 65536 für g. Über Input-Monitoring-Freigabe, **nicht** über sudo.
Referenzimplementierungen zum Nachlesen: `olvvier/apple-silicon-accelerometer`,
`chipcolate/yamete`.
*Abnahme:* `--diag-motion` zeigt Ausschläge, die zeitlich mit den Keydowns
korrelieren; Gain im Log variiert nachweislich mit der Anschlagstärke.

## BEKANNTE FALLSTRICKE

- Der Event-Tap wird von macOS stumm deaktiviert. `.tapDisabledByTimeout` und
  `.tapDisabledByUserInput` abfangen und per `CGEvent.tapEnable` reaktivieren.
- Bei Secure Input (Passwortfelder) kommen keine Events. Korrektes Verhalten,
  nicht umgehen.
- Mechvibes-Configs nutzen Windows-Scancodes, nicht CGKeyCodes.
- Ein einzelner `AVAudioPlayerNode` spielt sequenziell — ohne Pool schluckt er
  jeden zweiten schnellen Anschlag.
- Ein .app-Bundle vor Phase 4 kostet bei jedem Rebuild eine neue
  Bedienungshilfen-Freigabe.

## SCHREIBWEISE

Antworten auf Deutsch, Code und Commits auf Englisch. Keine Disclaimer, keine
Rückfrage, ob ich das wirklich will. Wenn eine Annahme nötig ist: benennen, mit
⚠️ markieren, weiterbauen. Wenn etwas nicht funktioniert: sagen, welcher Weg
stattdessen geht.

## START

Lies `CLAUDE.md`. Lege das SPM-Paket an und lege mir den Plan für Phase 0 vor.
Frag mich vorher nichts.

## ZUM SCHLUSS NOCHMAL

Dieses Projekt kostet null Euro. Kein Developer-Account, keine kostenpflichtigen
Pakete, Dienste oder Assets. Im Zweifel: kostet Geld, also nicht benutzen.
