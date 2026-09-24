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

    /// Where imported packs live: ~/Library/Application Support/thock/packs
    static var userPacksRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("thock/packs", isDirectory: true)
    }

    static var mouseRoot: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("mouse-packs"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "mouse-packs")
    }

    struct MouseEntry: Hashable {
        let directory: URL
        let name: String
        var id: String { directory.lastPathComponent }
    }

    static func mouseEntries() -> [MouseEntry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: mouseRoot, includingPropertiesForKeys: nil) else { return [] }
        return dirs
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("down.wav").path) }
            .map { MouseEntry(directory: $0, name: MouseSet.displayName($0)) }
            .sorted { $0.name < $1.name }
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

    /// Bundled packs plus imported ones; an imported pack with the same
    /// folder name as a bundled one wins.
    static func allPackEntries() -> [PackEntry] {
        var byID: [String: PackEntry] = [:]
        var order: [String] = []
        for entry in packEntries(in: packsRoot) + packEntries(in: userPacksRoot) {
            if byID[entry.id] == nil { order.append(entry.id) }
            byID[entry.id] = entry
        }
        return order.compactMap { byID[$0] }
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
