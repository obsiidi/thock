import AppKit
import Charts
import CoreText
import SwiftUI

// MARK: - Brand fonts (bundled OFL fonts, system fallback)

enum BrandFont {
    private static var registered = false

    /// Registers Archivo and JetBrains Mono for this process (bundle or cwd).
    static func register() {
        guard !registered else { return }
        registered = true
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("fonts"),
                    URL(fileURLWithPath: "site/fonts")].compactMap { $0 }
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "woff2" {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            if !files.isEmpty { break }
        }
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let name: String
        switch weight {
        case .heavy, .black: name = "ArchivoRoman-ExtraBold"
        case .medium: name = "ArchivoRoman-Medium"
        default: name = "ArchivoRoman-Bold"
        }
        return NSFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat) -> Font {
        NSFont(name: "JetBrainsMono-Regular", size: size) != nil
            ? .custom("JetBrainsMono-Regular", size: size)
            : .system(size: size, design: .monospaced)
    }
}

// MARK: - Dot-matrix wordmark (same look as the website)

struct DotWordmark: View {
    var text = "thock"
    var ink: Color
    var step: CGFloat

    var body: some View {
        Canvas { ctx, size in
            for d in DotWordmark.dots(text: text, size: size, step: step) {
                let r = d.radius
                ctx.fill(Path(ellipseIn: CGRect(x: d.point.x - r, y: d.point.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(ink.opacity(d.alpha)))
            }
        }
    }

    struct Dot { let point: CGPoint; let radius: CGFloat; let alpha: Double }

    /// Renders the word into a grayscale bitmap and samples coverage on a grid.
    static func dots(text: String, size: CGSize, step: CGFloat) -> [Dot] {
        let scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let fontName = NSFont(name: "ArchivoRoman-ExtraBold", size: 10) != nil ? "ArchivoRoman-ExtraBold" : "Helvetica-Bold"
        func line(_ fs: CGFloat) -> CTLine {
            let font = CTFontCreateWithName(fontName as CFString, fs, nil)
            let attr = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
            return CTLineCreateWithAttributedString(attr)
        }
        let probe = CTLineGetBoundsWithOptions(line(100), .useGlyphPathBounds)
        let fs = min(CGFloat(w) * 0.94 / max(1, probe.width) * 100, CGFloat(h) * 0.92 / max(1, probe.height) * 100)
        let l = line(fs)
        let b = CTLineGetBoundsWithOptions(l, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: (CGFloat(w) - b.width) / 2 - b.minX, y: (CGFloat(h) - b.height) / 2 - b.minY)
        CTLineDraw(l, ctx)
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }

        let cols = Int(size.width / step), rows = Int(size.height / step)
        let ox = (size.width - CGFloat(cols - 1) * step) / 2, oy = (size.height - CGFloat(rows - 1) * step) / 2
        var out: [Dot] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let cx = ox + CGFloat(c) * step, cy = oy + CGFloat(r) * step
                var sum = 0.0
                for sy in 0..<3 {
                    for sx in 0..<3 {
                        let px = min(w - 1, max(0, Int((cx - step / 2 + (CGFloat(sx) + 0.5) * step / 3) * scale)))
                        // bitmap memory is top-down; drawing coordinates are bottom-up
                        let py = min(h - 1, max(0, Int((cy - step / 2 + (CGFloat(sy) + 0.5) * step / 3) * scale)))
                        sum += Double(data[py * w + px]) / 255
                    }
                }
                let a = min(1, sum / 9 * 1.12)
                guard a > 0.035 else { continue }
                out.append(Dot(point: CGPoint(x: cx, y: cy), radius: step * 0.54 * CGFloat(pow(a, 0.58)), alpha: 0.28 + 0.72 * a))
            }
        }
        return out
    }
}

// MARK: - Keyboard heatmap

struct KeyboardHeatmap: View {
    let counts: [Int]
    let labels: [String]
    var unit: CGFloat = 34
    var gap: CGFloat = 4
    var ink: Color = .primary
    var base: Color = Color(nsColor: .windowBackgroundColor)
    var labelFont: Font = .system(size: 10, weight: .medium)

    var body: some View {
        let maxCount = max(1, counts.max() ?? 1)
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(KeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        let n = key.code < counts.count ? counts[key.code] : 0
                        let t = n == 0 ? 0 : 0.12 + 0.88 * sqrt(Double(n) / Double(maxCount))
                        RoundedRectangle(cornerRadius: unit * 0.14)
                            .fill(ink.opacity(n == 0 ? 0.06 : t))
                            .overlay(
                                Text(key.code < labels.count ? labels[key.code] : "")
                                    .font(labelFont)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .foregroundColor(t > 0.55 ? base : ink.opacity(0.75))
                                    .padding(.horizontal, 2)
                            )
                            .frame(width: unit * key.width + gap * (key.width - 1), height: unit)
                            .help(n == 0 ? "" : "\(StatsFormat.number(n)) presses")
                    }
                }
            }
        }
    }
}

// MARK: - Share card (1200 × 630, website look)

struct ShareCard: View {
    let summary: StatsSummary
    let labels: [String]

    private let bg = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    private let ink = Color(red: 237 / 255, green: 237 / 255, blue: 231 / 255)
    private let dim = Color(red: 141 / 255, green: 141 / 255, blue: 133 / 255)

    var body: some View {
        let week = summary.week
        let active = TypingStats.activeMinutes(Array(summary.last14.suffix(7)))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                DotWordmark(ink: ink, step: 3.2).frame(width: 190, height: 50)
                Spacer()
                Text("MY TYPING WEEK · \(ShareCard.range(summary))")
                    .font(BrandFont.mono(15)).tracking(2.5).foregroundColor(dim)
            }
            Spacer(minLength: 28)
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 26) {
                    metric(StatsFormat.number(week.keys), "keystrokes")
                    HStack(alignment: .top, spacing: 40) {
                        metric("\(week.peakWPM)", "wpm peak", size: 44)
                        metric(StatsFormat.duration(minutes: active), "typing", size: 44)
                    }
                    if summary.streak > 1 {
                        metric("\(summary.streak) days", "streak", size: 44)
                    } else if let hk = week.hardestKey {
                        metric(labels[hk.keyCode], "hardest-hit key", size: 44)
                    }
                }
                .frame(width: 420, alignment: .leading)
                KeyboardHeatmap(counts: week.perKey, labels: labels, unit: 37, gap: 5,
                                ink: ink, base: bg, labelFont: BrandFont.mono(11))
            }
            Spacer(minLength: 24)
            HStack {
                Text("Counted on my Mac. Never uploaded.")
                    .font(BrandFont.mono(15)).foregroundColor(dim)
                Spacer()
                Text("thock-ecru.vercel.app")
                    .font(BrandFont.mono(15)).foregroundColor(ink)
            }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 50)
        .frame(width: 1200, height: 630)
        .background(bg)
    }

    private func metric(_ value: String, _ label: String, size: CGFloat = 76) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(BrandFont.display(size)).foregroundColor(ink)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label.uppercased()).font(BrandFont.mono(13)).tracking(2).foregroundColor(dim)
        }
    }

    static func range(_ s: StatsSummary) -> String {
        let days = s.last14.suffix(7)
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.dateFormat = "d MMM"
        guard let a = days.first.flatMap({ parse.date(from: $0.date) }),
              let b = days.last.flatMap({ parse.date(from: $0.date) }) else { return "" }
        return "\(out.string(from: a)) – \(out.string(from: b))".uppercased()
    }

    /// Renders the card at 2× (2400 × 1260 px).
    @MainActor
    static func render(summary: StatsSummary, labels: [String]) -> NSImage? {
        BrandFont.register()
        let renderer = ImageRenderer(content: ShareCard(summary: summary, labels: labels))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 1200, height: 630))
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

// MARK: - Stats window

final class StatsModel: ObservableObject {
    @Published var summary: StatsSummary
    let stats: TypingStats
    let labels = KeyboardLayout.labels()
    private var timer: Timer?

    init(stats: TypingStats) {
        self.stats = stats
        summary = stats.summary()
    }

    func startRefreshing() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() { summary = stats.summary() }
}

struct StatsView: View {
    enum Scope: String, CaseIterable { case today = "Today", week = "7 days" }

    @ObservedObject var model: StatsModel
    @ObservedObject var state: AppState
    @State private var scope: Scope = .today
    @State private var confirmReset = false
    @State private var note = ""
    private let anchor = ShareAnchor()

    var body: some View {
        let s = model.summary
        let day = scope == .today ? s.today : s.week
        let active = scope == .today ? s.today.activeMinuteCount
                                     : TypingStats.activeMinutes(Array(s.last14.suffix(7)))
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Your typing").font(.title2.bold())
                Spacer()
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            HStack(spacing: 12) {
                tile(StatsFormat.number(day.keys), "keystrokes")
                tile("\(day.peakWPM)", "wpm peak")
                tile(StatsFormat.duration(minutes: active), "typing time")
                tile(s.streak > 0 ? "\(s.streak) d" : "–", "streak")
            }

            KeyboardHeatmap(counts: day.perKey, labels: model.labels, unit: 38, gap: 4)
                .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last 14 days").font(.headline)
                    Chart(s.last14, id: \.date) { d in
                        BarMark(x: .value("Day", String(d.date.suffix(2))), y: .value("Keys", d.keys))
                            .foregroundStyle(d.date == s.today.date ? Color.accentColor : Color.primary.opacity(0.55))
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 140)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    if day.forceSamples > 0 {
                        Text("Key force").font(.headline)
                        Chart(Array(day.forceHist.enumerated()), id: \.offset) { i, n in
                            BarMark(x: .value("Force", i == 0 ? "soft" : (i == DayStats.forceBuckets - 1 ? "hard" : "\(i)")),
                                    y: .value("Hits", n))
                                .foregroundStyle(Color.primary.opacity(0.35 + 0.065 * Double(i)))
                        }
                        .chartXAxis { AxisMarks(values: ["soft", "hard"]) }
                        .frame(height: 140)
                    } else {
                        Text("Records").font(.headline)
                    }
                    records(s, day)
                }
                .frame(width: 230, alignment: .leading)
            }

            Text("Counts only — never what you type. Stored on this Mac in ~/Library/Application Support/thock/stats.json.")
                .font(.caption).foregroundColor(.secondary)

            HStack(spacing: 10) {
                Toggle("Keep typing stats", isOn: $state.keepStats)
                Button("Reset…") { confirmReset = true }
                Spacer()
                if !note.isEmpty { Text(note).font(.caption).foregroundColor(.secondary) }
                Button("Copy image") { copyImage() }
                Button("Save image…") { saveImage() }
                Button("Share…") { share() }
                    .background(ShareAnchorView(anchor: anchor))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 720)
        .onAppear { model.startRefreshing() }
        .onDisappear { model.stopRefreshing() }
        .alert("Reset typing stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.stats.reset(); model.refresh() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All days are deleted from this Mac. This cannot be undone.")
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26, weight: .bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(.caption2).foregroundColor(.secondary).tracking(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func records(_ s: StatsSummary, _ day: DayStats) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            row("Best day", s.bestDayKeys > 0 ? "\(StatsFormat.number(s.bestDayKeys)) keys" : "–")
            row("Best speed", s.bestWPM > 0 ? "\(s.bestWPM) wpm" : "–")
            row("All time", "\(StatsFormat.number(s.totalKeys)) keys")
            if let hk = day.hardestKey {
                row("Hardest-hit key", model.labels[hk.keyCode])
            }
            if day.clicks > 0 {
                row("Clicks", StatsFormat.number(day.clicks))
            }
        }
        .font(.callout)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundColor(.secondary); Spacer(); Text(v).monospacedDigit() }
    }

    // MARK: sharing

    @MainActor private func cardImage() -> NSImage? {
        ShareCard.render(summary: model.summary, labels: model.labels)
    }

    @MainActor private func copyImage() {
        guard let img = cardImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        note = "Copied"
    }

    @MainActor private func saveImage() {
        guard let img = cardImage(), let png = ShareCard.pngData(img) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "thock-week-\(model.summary.today.date).png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            do { try png.write(to: url); note = "Saved" } catch { note = "Could not save" }
        }
    }

    @MainActor private func share() {
        guard let img = cardImage(), let png = ShareCard.pngData(img) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thock-week-\(model.summary.today.date).png")
        guard (try? png.write(to: url)) != nil, let view = anchor.view else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
}

/// Gives SwiftUI buttons an NSView to anchor the share picker to.
final class ShareAnchor { weak var view: NSView? }

struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

final class StatsWindow {
    private var window: NSWindow?
    private var model: StatsModel?

    func show(state: AppState) {
        BrandFont.register()
        if let w = window {
            model?.refresh()
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let m = StatsModel(stats: state.typing)
        model = m
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "thock — Typing stats"
        w.contentViewController = NSHostingController(rootView: StatsView(model: m, state: state))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
