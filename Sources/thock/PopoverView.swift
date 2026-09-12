import SwiftUI

struct PopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "keyboard")
                Text("thock").font(.headline)
                Spacer()
                Circle()
                    .fill(state.running ? Color.green : (state.permissionGranted ? Color.orange : Color.red))
                    .frame(width: 9, height: 9)
            }

            Picker("Sound", selection: $state.selectedPack) {
                ForEach(state.packs, id: \.id) { pack in
                    Text(pack.name).tag(pack.id)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Image(systemName: "speaker.wave.2")
                Slider(value: $state.volume, in: 0...1)
                Text("\(Int(state.volume * 100)) %")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }

            Toggle("Loslass-Geräusche", isOn: $state.keyUpSounds)
                .toggleStyle(.switch)
                .disabled(!state.packHasKeyUp)
                .help(state.packHasKeyUp ? "Dieses Pack hat eigene Geräusche fürs Loslassen der Taste."
                                         : "Dieses Pack hat keine Loslass-Geräusche.")

            Toggle("Beim Anmelden starten", isOn: $state.launchAtLogin)
                .toggleStyle(.switch)

            if !state.permissionGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Eingabeüberwachung fehlt", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Button("Systemeinstellungen öffnen") {
                        state.openInputMonitoringSettings()
                    }
                }
            }

            Text(state.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Spacer()
                Button("Beenden") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
