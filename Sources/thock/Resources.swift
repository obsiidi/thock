import Foundation

/// Locates packs and the built-in click: inside the .app bundle when
/// running as an app, otherwise relative to the working directory (CLI
/// development loop with `swift run`).
enum Resources {
    static var packsRoot: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("packs"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "packs")
    }

    static var clickURL: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Samples/click.wav"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "Samples/click.wav")
    }

    /// Pack folders with their display names from config.json (no audio decoding).
    struct PackEntry: Hashable {
        let directory: URL
        let name: String
        var id: String { directory.lastPathComponent }
    }

    static func packEntries(in root: URL) -> [PackEntry] {
        SoundpackLoader.listPacks(in: root).map { dir in
            var name = dir.lastPathComponent
            if let data = FileManager.default.contents(atPath: dir.appendingPathComponent("config.json").path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let n = obj["name"] as? String, !n.isEmpty {
                name = n
            }
            return PackEntry(directory: dir, name: name)
        }
    }
}
