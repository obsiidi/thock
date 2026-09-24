import Foundation

/// One calendar day of typing statistics. Counts only: no characters, no
/// order, no per-keystroke timestamps.
struct DayStats: Codable, Equatable {
    static let keySlots = 128
    static let minuteWords = 23            // 23 × 64 bits ≥ 1440 minutes
    static let forceBuckets = 10

    var date: String                       // yyyy-MM-dd, local time
    var keys = 0
    var perKey = [Int](repeating: 0, count: keySlots)
    var activeMinutes = [UInt64](repeating: 0, count: minuteWords)
    var peakKPM = 0                        // most key-downs in any 60 s window
    var forceHist = [Int](repeating: 0, count: forceBuckets)
    var forceSum = [Float](repeating: 0, count: keySlots)
    var forceCount = [Int](repeating: 0, count: keySlots)
    var clicks = 0
    var scrollPoints: Double = 0

    init(date: String) {
        self.date = date
    }

    var activeMinuteCount: Int {
        activeMinutes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    var peakWPM: Int { peakKPM / 5 }

    var forceSamples: Int { forceHist.reduce(0, +) }

    /// Key with the highest average measured force (needs a few hits).
    var hardestKey: (keyCode: Int, force: Float)? {
        var best: (Int, Float)?
        for k in 0..<DayStats.keySlots where forceCount[k] >= 5 {
            let avg = forceSum[k] / Float(forceCount[k])
            if best == nil || avg > best!.1 { best = (k, avg) }
        }
        return best.map { (keyCode: $0.0, force: $0.1) }
    }

    /// Tolerant decoding: files from older versions or damaged arrays
    /// fall back to empty slots instead of failing the whole history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        keys = (try? c.decode(Int.self, forKey: .keys)) ?? 0
        perKey = DayStats.fit((try? c.decode([Int].self, forKey: .perKey)) ?? [], DayStats.keySlots, 0)
        activeMinutes = DayStats.fit((try? c.decode([UInt64].self, forKey: .activeMinutes)) ?? [], DayStats.minuteWords, 0)
        peakKPM = (try? c.decode(Int.self, forKey: .peakKPM)) ?? 0
        forceHist = DayStats.fit((try? c.decode([Int].self, forKey: .forceHist)) ?? [], DayStats.forceBuckets, 0)
        forceSum = DayStats.fit((try? c.decode([Float].self, forKey: .forceSum)) ?? [], DayStats.keySlots, 0)
        forceCount = DayStats.fit((try? c.decode([Int].self, forKey: .forceCount)) ?? [], DayStats.keySlots, 0)
        clicks = (try? c.decode(Int.self, forKey: .clicks)) ?? 0
        scrollPoints = (try? c.decode(Double.self, forKey: .scrollPoints)) ?? 0
    }

    private static func fit<T>(_ a: [T], _ n: Int, _ fill: T) -> [T] {
        a.count == n ? a : Array((a + [T](repeating: fill, count: n)).prefix(n))
    }
}

/// Summary numbers the UI shows.
struct StatsSummary {
    var today: DayStats
    var last14: [DayStats]          // oldest first, today last, gaps filled
    var week: DayStats              // last 7 days merged
    var streak: Int                 // consecutive days with ≥ streakThreshold keys
    var bestDayKeys: Int
    var bestDayDate: String?
    var bestWPM: Int
    var totalKeys: Int
    var totalDays: Int
}

/// Collects typing statistics on the drain thread (never the real-time
/// path) and persists them to a local JSON file. Thread-safe.
final class TypingStats {
    static let streakThreshold = 200
    static let retentionDays = 400

    let fileURL: URL
    /// Count synthetic events too (self-tests only).
    let countSynthetic: Bool

    private let lock = NSLock()
    private var history: [DayStats] = []          // past days, oldest first
    private var today: DayStats
    private var dirty = false
    private var enabledFlag = true
    // 60 s sliding window of key-downs per second
    private var perSecond = [Int](repeating: 0, count: 60)
    private var lastSecond = 0
    private var windowSum = 0
    private var flushTimer: DispatchSourceTimer?

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["THOCK_STATS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Resources.userPacksRoot.deletingLastPathComponent().appendingPathComponent("stats.json")
    }

    init(fileURL: URL = TypingStats.defaultURL, countSynthetic: Bool = false) {
        self.fileURL = fileURL
        self.countSynthetic = countSynthetic
        today = DayStats(date: TypingStats.dayString(Date()))
        load()
    }

    deinit {
        flushTimer?.cancel()
    }

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabledFlag }
        set { lock.lock(); enabledFlag = newValue; lock.unlock() }
    }

    // MARK: recording (drain thread)

    func record(_ e: KeyEvent, now: Date = Date()) {
        if e.synthetic != 0 && !countSynthetic { return }
        guard e.kind == .keyDown, e.autorepeat == 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard enabledFlag else { return }
        rollOverIfNeeded(now)

        today.keys += 1
        let k = Int(e.keyCode & 127)
        today.perKey[k] += 1

        let minute = TypingStats.minuteOfDay(now)
        today.activeMinutes[minute >> 6] |= (1 << UInt64(minute & 63))

        let second = Int(now.timeIntervalSince1970)
        if second != lastSecond {
            let gap = second - lastSecond
            if gap >= 60 || gap < 0 {
                perSecond = [Int](repeating: 0, count: 60)
                windowSum = 0
            } else {
                for s in 1...gap {
                    let slot = (lastSecond + s) % 60
                    windowSum -= perSecond[slot]
                    perSecond[slot] = 0
                }
            }
            lastSecond = second
        }
        perSecond[second % 60] += 1
        windowSum += 1
        if windowSum > today.peakKPM { today.peakKPM = windowSum }

        if e.forceMeasured != 0 {
            let f = min(1, max(0, e.force))
            today.forceHist[min(DayStats.forceBuckets - 1, Int(f * Float(DayStats.forceBuckets)))] += 1
            today.forceSum[k] += f
            today.forceCount[k] += 1
        }
        dirty = true
    }

    func recordClick(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard enabledFlag else { return }
        rollOverIfNeeded(now)
        today.clicks += 1
        dirty = true
    }

    func recordScroll(points: Double, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard enabledFlag else { return }
        rollOverIfNeeded(now)
        today.scrollPoints += abs(points)
        dirty = true
    }

    /// Caller holds the lock.
    private func rollOverIfNeeded(_ now: Date) {
        let d = TypingStats.dayString(now)
        guard d != today.date else { return }
        if today.keys > 0 || today.clicks > 0 { history.append(today) }
        today = DayStats(date: d)
        perSecond = [Int](repeating: 0, count: 60)
        windowSum = 0
        if history.count > TypingStats.retentionDays {
            history.removeFirst(history.count - TypingStats.retentionDays)
        }
    }

    // MARK: queries (any thread)

    func summary(now: Date = Date()) -> StatsSummary {
        lock.lock()
        rollOverIfNeeded(now)
        let past = history
        let current = today
        lock.unlock()

        let byDate = Dictionary(past.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        var last14: [DayStats] = []
        for offset in stride(from: 13, through: 0, by: -1) {
            let d = TypingStats.dayString(Calendar.current.date(byAdding: .day, value: -offset, to: now) ?? now)
            if d == current.date { last14.append(current) } else { last14.append(byDate[d] ?? DayStats(date: d)) }
        }
        let week = TypingStats.merge(Array(last14.suffix(7)), date: current.date)

        // Streak: count back from today; today may still be below threshold.
        var streak = 0
        var offset = current.keys >= TypingStats.streakThreshold ? 0 : 1
        if offset == 0 { streak = 1; offset = 1 }
        while true {
            let d = TypingStats.dayString(Calendar.current.date(byAdding: .day, value: -offset, to: now) ?? now)
            guard let day = byDate[d], day.keys >= TypingStats.streakThreshold else { break }
            streak += 1
            offset += 1
        }

        let all = past + [current]
        let best = all.max { $0.keys < $1.keys }
        return StatsSummary(
            today: current,
            last14: last14,
            week: week,
            streak: streak,
            bestDayKeys: best?.keys ?? 0,
            bestDayDate: best?.date,
            bestWPM: all.map { $0.peakWPM }.max() ?? 0,
            totalKeys: all.reduce(0) { $0 + $1.keys },
            totalDays: all.filter { $0.keys > 0 }.count
        )
    }

    static func merge(_ days: [DayStats], date: String) -> DayStats {
        var m = DayStats(date: date)
        for d in days {
            m.keys += d.keys
            m.peakKPM = max(m.peakKPM, d.peakKPM)
            m.clicks += d.clicks
            m.scrollPoints += d.scrollPoints
            for k in 0..<DayStats.keySlots {
                m.perKey[k] += d.perKey[k]
                m.forceSum[k] += d.forceSum[k]
                m.forceCount[k] += d.forceCount[k]
            }
            for b in 0..<DayStats.forceBuckets { m.forceHist[b] += d.forceHist[b] }
        }
        return m
    }

    /// Active minutes across several days (the bit masks cannot be merged).
    static func activeMinutes(_ days: [DayStats]) -> Int {
        days.reduce(0) { $0 + $1.activeMinuteCount }
    }

    // MARK: persistence

    private struct FileFormat: Codable {
        var version: Int
        var days: [DayStats]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(FileFormat.self, from: data) else { return }
        var days = file.days.sorted { $0.date < $1.date }
        if let last = days.last, last.date == today.date {
            today = last
            days.removeLast()
        }
        history = Array(days.suffix(TypingStats.retentionDays))
    }

    /// Writes the file if anything changed since the last write.
    func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let file = FileFormat(version: 1, days: history + [today])
        dirty = false
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            stderrLine("thock: could not save stats: \(error.localizedDescription)")
            lock.lock(); dirty = true; lock.unlock()
        }
    }

    func startAutosave(every seconds: Double = 60) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "thock.stats"))
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        flushTimer = t
    }

    /// Deletes all statistics, in memory and on disk.
    func reset() {
        lock.lock()
        history = []
        today = DayStats(date: TypingStats.dayString(Date()))
        perSecond = [Int](repeating: 0, count: 60)
        windowSum = 0
        dirty = false
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: time helpers

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func minuteOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return min(1439, max(0, (c.hour ?? 0) * 60 + (c.minute ?? 0)))
    }
}

// MARK: - Formatting shared by UI, card and CLI

enum StatsFormat {
    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func todayLine(_ s: StatsSummary) -> String {
        var parts = ["Today \(number(s.today.keys)) keys"]
        if s.today.peakWPM > 0 { parts.append("\(s.today.peakWPM) wpm peak") }
        if s.streak > 1 { parts.append("\(s.streak)-day streak") }
        return parts.joined(separator: " · ")
    }
}
