import SwiftUI
import UniformTypeIdentifiers

struct PopoverView: View {
    @ObservedObject var state: AppState
    var showSetup: () -> Void = {}
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "keyboard")
                Text("thock").font(.headline)
                Spacer()
                Circle()
                    .fill(state.running && state.enabled ? Color.green
                          : (state.permissionGranted ? Color.orange : Color.red))
                    .frame(width: 9, height: 9)
                Toggle("", isOn: $state.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Keyboard sounds on / off")
            }

            HStack {
                Picker("Sound", selection: $state.selectedPack) {
                    ForEach(state.packs, id: \.id) { pack in
                        Text(pack.name).tag(pack.id)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    state.chooseAndImportPack()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Import a Mechvibes sound pack folder (or drop one onto this window)")
            }

            HStack {
                Image(systemName: "speaker.wave.2")
                Slider(value: $state.volume, in: 0...1)
                Text("\(Int(state.volume * 100)) %")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }

            if state.sensorAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Key force", isOn: $state.velocityEnabled)
                        .toggleStyle(.switch)
                        .help("Loudness and tone follow how hard you hit the key (motion sensor).")
                    HStack {
                        Text("soft").font(.caption2).foregroundColor(.secondary)
                        Slider(value: $state.sensitivitySlider, in: 0...1)
                            .disabled(!state.velocityEnabled)
                        Text("hard").font(.caption2).foregroundColor(.secondary)
                    }
                    .help("Sensitivity: left needs firm hits for full volume, right makes light taps loud.")
                }
            }

            Toggle("Key-release sounds", isOn: $state.keyUpSounds)
                .toggleStyle(.switch)
                .disabled(!state.packHasKeyUp)
                .help(state.packHasKeyUp ? "This pack has its own sounds for releasing a key."
                                         : "This pack has no key-release sounds.")

            Toggle("Launch at login", isOn: $state.launchAtLogin)
                .toggleStyle(.switch)

            if !state.permissionGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Input Monitoring not allowed", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Button("Open System Settings") {
                        state.openInputMonitoringSettings()
                    }
                }
            }

            if let update = state.update {
                Button {
                    NSWorkspace.shared.open(update.url)
                } label: {
                    Label("Update available: v\(update.version)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.link)
            }

            Text(state.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 10) {
                Text("v\(state.version)").font(.caption).foregroundColor(.secondary)
                Button("Setup") { showSetup() }.buttonStyle(.link).font(.caption)
                Button("Packs folder") { state.revealPacksFolder() }.buttonStyle(.link).font(.caption)
                Button("Feedback") { state.openFeedback() }.buttonStyle(.link).font(.caption)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: dropTargeted ? 2 : 0)
                .padding(4)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                if let u = item as? URL { url = u }
                guard let folder = url else { return }
                DispatchQueue.main.async { state.importPack(from: folder) }
            }
            return true
        }
    }
}
