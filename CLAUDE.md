# thock

macOS-Menüleisten-App: spielt mechanische Tastaturgeräusche beim Tippen auf der
eingebauten MacBook-Tastatur. Rein privat, läuft nur auf dem Mac des Entwicklers.
Keine Veröffentlichung, kein Vertrieb, kein App Store.

---

## Regel 0 — Das Projekt kostet null Euro

Nichts in diesem Projekt darf Geld kosten. Nicht jetzt, nicht später, nicht
„nur für den Anfang".

Verboten ohne Ausnahme:

- Kostenpflichtige Dienste, APIs, Abos, Testzeiträume mit Zahlungsdaten
- Apple Developer Program ($99/Jahr) — wird für eine private App nicht gebraucht
- Kostenpflichtige Pakete, Assets, Fonts, Sound-Bibliotheken, Lizenzen
- Alles, was ein Konto mit hinterlegter Zahlungsmethode verlangt

**Tiebreaker: Wenn unklar ist, ob etwas Geld kostet, kostet es Geld. Nicht
benutzen, stattdessen eine kostenlose Alternative vorschlagen.**

Erlaubt ist ausschließlich: Xcode Command Line Tools, Swift Toolchain, Apples
System-Frameworks, Open-Source-Code mit permissiver Lizenz, selbstsignierte
Zertifikate aus der Schlüsselbundverwaltung.

---

## Stack

- Swift Package Manager, Executable-Target. **Kein Xcode-Projekt bis Phase 4.**
- macOS 13+, Apple Silicon
- Nur Apple-Frameworks: Foundation, AppKit, AVFoundation, CoreGraphics, IOKit
- **Null externe Dependencies.** Wenn ein Package nötig scheint: erst fragen.

## Module

```
Sources/thock/
  KeyTap.swift          CGEventTap, Tastenerfassung
  EventRing.swift       SPSC-Ring Tap → Trigger → Log
  Pipeline.swift        Trigger-Thread: Tap-Events → Audio, Pitch-Jitter
  AudioEngine.swift     AVAudioEngine, Geräte-/Puffer-Setup, Overload-Zähler
  VoiceMixer.swift      AVAudioSourceNode, 16 Voices, Sample-Tabelle (Phase 2:
                        ersetzt den AVAudioPlayerNode-Pool, siehe PROGRESS.md)
  SoundpackLoader.swift Mechvibes-config.json parsen, Buffer schneiden
  Scancodes.swift       CGKeyCode ↔ Windows-Scancode Mapping
  Motion.swift          SPU-Accelerometer (Phase 5, optional)
  StatusBar.swift       NSStatusItem, Einstellungen (Phase 4)
  Diagnostics.swift     --diag / --selftest
```

---

## Harte technische Regeln

**Echtzeit-Pfad.** Im Audio-Render-Callback und im Event-Tap-Callback: keine
Allokation, keine Locks, keine Logs, kein String-Handling, keine Dictionary-
Lookups mit Hashing. Alles vorberechnet, Arrays mit festem Index.

**Event-Tap.** Immer `.listenOnly` an `.cgSessionEventTap`. Der Callback muss
`.tapDisabledByTimeout` und `.tapDisabledByUserInput` abfangen und den Tap per
`CGEvent.tapEnable` reaktivieren — sonst verstummt die App nach Stunden
kommentarlos. Bei Secure Input (Passwortfelder) kommen keine Events: das ist
korrekt und wird nicht umgangen.

**Scancodes.** Mechvibes-Soundpacks mappen **Windows-Scancodes**, nicht macOS-
Keycodes. `"57"` = Space, `"28"` = Enter, `"14"` = Backspace. Ohne
Übersetzungstabelle klingt jede Taste falsch. Die Tabelle ist Quellcode, kein
Ratespiel — bei Unsicherheit lieber weniger Tasten mappen und den Rest auf den
Default-Sound fallen lassen.

**Polyphonie.** Ein `AVAudioPlayerNode` spielt Buffer sequenziell. Schnelles
Tippen braucht Überlappung → Pool von 16 Nodes im Round-Robin.

**Kein sudo.** Niemals. Sensorzugriff läuft über die Input-Monitoring-Freigabe,
nicht über Root.

---

## Entwicklungs-Loop

Phase 0–3 laufen als CLI-Binary aus dem Terminal. Der Prozess erbt die
Bedienungshilfen-Freigabe von Terminal.app — einmal erteilen, dann über alle
Rebuilds stabil. Ein .app-Bundle vor Phase 4 bricht das und kostet bei jedem
Build eine neue Freigabe.

**Claude kann nichts hören.** Jede Verifikation läuft über messbaren Output:

- `--diag` — eine Logzeile pro Anschlag: keyCode, Scancode, Sample-ID, Gain,
  Latenz von CGEvent-Timestamp bis `scheduleBuffer` in Mikrosekunden
- `--selftest` — feuert N synthetische Anschläge, gibt Latenz-Median, p95 und
  Dropout-Zahl aus, endet mit Exit-Code 0 oder 1

Abnahme einer Phase = `swift build` ohne Warnungen **und** `swift run thock
--selftest` mit Exit-Code 0. „Sieht fertig aus" zählt nicht.

---

## Arbeitsweise

- Eine Phase pro Durchlauf. Am Ende jeder Phase: Commit, kurzer Bericht, Stopp.
- Vor dem ersten Code jeder Phase: Plan vorlegen, auf Freigabe warten.
- `PROGRESS.md` nach jeder Phase aktualisieren (Stand, offene Punkte, nächster
  Schritt), damit eine neue Sitzung ohne Kontext weiterarbeiten kann.
- Commit-Messages und Code-Kommentare auf Englisch, Antworten im Chat auf Deutsch.

## Nie ohne Rückfrage

- Dateien außerhalb des Projektordners anfassen
- Systemeinstellungen oder TCC-Datenbank verändern
- Fremde Binaries herunterladen und ausführen
- Externe Packages hinzufügen
- Irgendetwas, das Geld kostet — siehe Regel 0
