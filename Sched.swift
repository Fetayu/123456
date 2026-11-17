import Foundation

enum Sched {
    static let on = 0
    static let off = 1
    static let maybe = 2

    static let kyiv: TimeZone =
        TimeZone(identifier: "Europe/Kyiv") ?? TimeZone(identifier: "Europe/Kiev") ?? TimeZone(secondsFromGMT: 7200)!

    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kyiv
        return c
    }

    // MARK: - допоміжні

    static func fmt(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = kyiv
        f.dateFormat = pattern
        return f.string(from: d)
    }

    static func parse(_ s: String, _ pattern: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = kyiv
        f.dateFormat = pattern
        return f.date(from: s)
    }

    static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func code(_ s: String) -> Character {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes": return "y"
        case "no": return "n"
        case "maybe": return "m"
        case "first": return "f"
        case "second": return "s"
        case "mfirst": return "a"
        case "msecond": return "b"
        default: return "u"
        }
    }

    private static func weekdayFromName(_ n: String) -> Int {
        if n.hasPrefix("пон") || n.hasPrefix("пн") { return 0 }
        if n.hasPrefix("вів") || n.hasPrefix("вт") { return 1 }
        if n.hasPrefix("сер") || n.hasPrefix("ср") { return 2 }
        if n.hasPrefix("чет") || n.hasPrefix("чт") { return 3 }
        if n.hasPrefix("п'я") || n.hasPrefix("п’я") || n.hasPrefix("пят") || n.hasPrefix("пт") { return 4 }
        if n.hasPrefix("суб") || n.hasPrefix("сб") { return 5 }
        if n.hasPrefix("нед") || n.hasPrefix("нд") { return 6 }
        return -1
    }

    /// Які ключі в preset означають які дні тижня (0 = понеділок).
    private static func dayKeyMap(_ preset: [String: Any]?) -> [String: Int] {
        var m: [String: Int] = [:]
        if let days = preset?["days"] as? [String: Any] {
            for (k, v) in days {
                let idx = weekdayFromName(str(v).trimmingCharacters(in: .whitespaces).lowercased())
                if idx >= 0 { m[k] = idx }
            }
        }
        if m.count < 7 {
            for i in 1...7 where m[String(i)] == nil { m[String(i)] = i - 1 }
        }
        return m
    }

    /// Один день з відповіді сайту -> рядок із 24 символів.
    private static func daySlots(_ o: [String: Any]?) -> String? {
        guard let o = o else { return nil }
        let base = (o["0"] != nil && o["24"] == nil) ? 0 : 1
        var out = ""
        var found = 0
        for h in 0..<24 {
            if let v = o[String(h + base)] as? String {
                out.append(code(v))
                found += 1
            } else {
                out.append("u")
            }
        }
        return found >= 12 ? out : nil
    }

    private static func dateStr(_ ts: Int64) -> String {
        let ms: Int64 = ts < 100_000_000_000 ? ts * 1000 : ts
        return fmt(Date(timeIntervalSince1970: Double(ms) / 1000.0), "dd.MM.yyyy")
    }

    /// Робить графік для групи або повертає nil, якщо структура незнайома.
    static func build(raw: String, groupId: String) -> SchedData? {
        if groupId.isEmpty { return nil }
        guard let root = json(raw) else { return nil }

        let preset = root["preset"] as? [String: Any]
        let presetData = (preset?["data"] as? [String: Any]) ?? preset
        var presetDays = [String?](repeating: nil, count: 7)
        if let g = presetData?[groupId] as? [String: Any] {
            let map = dayKeyMap(preset)
            for (k, v) in g {
                guard let idx = map[k], idx >= 0, idx < 7 else { continue }
                presetDays[idx] = daySlots(v as? [String: Any])
            }
        }

        var fact: [String: String] = [:]
        var factKeys = 0
        let factRoot = root["fact"] as? [String: Any]
        let factData = (factRoot?["data"] as? [String: Any]) ?? factRoot
        if let fd = factData {
            for (k, v) in fd {
                guard let ts = Int64(k) else { continue }
                factKeys += 1
                guard let day = v as? [String: Any],
                      let g = day[groupId] as? [String: Any],
                      let s = daySlots(g) else { continue }
                fact[dateStr(ts)] = s
            }
        }

        if presetDays.allSatisfy({ $0 == nil }) && fact.isEmpty { return nil }
        return SchedData(
            groupId: groupId,
            preset: presetDays.map { $0 ?? "" },
            fact: fact,
            updated: str(factRoot?["update"]),
            factKeys: factKeys
        )
    }

    /// Початок відповіді сайту + фрагменти preset і fact для діагностики.
    static func diag(_ raw: String) -> String {
        guard let root = json(raw) else { return String(raw.prefix(1500)) }
        func dump(_ o: Any) -> String {
            guard let d = try? JSONSerialization.data(withJSONObject: o),
                  let s = String(data: d, encoding: .utf8) else { return "" }
            return s
        }
        var out = String(raw.prefix(600))
        if let p = root["preset"] { out += "\n\n[preset] " + String(dump(p).prefix(1200)) }
        if let f = root["fact"] { out += "\n\n[fact] " + String(dump(f).prefix(800)) }
        return out
    }

    // MARK: - дати і інтервали

    /// 0 = понеділок ... 6 = неділя
    static func todayIdx(_ now: Date = Date()) -> Int {
        (cal.component(.weekday, from: now) + 5) % 7
    }

    static func nowMinutes(_ now: Date = Date()) -> Int {
        let c = cal
        return c.component(.hour, from: now) * 60 + c.component(.minute, from: now)
    }

    static func nowSeconds(_ now: Date = Date()) -> Int {
        let c = cal
        return c.component(.hour, from: now) * 3600 + c.component(.minute, from: now) * 60 + c.component(.second, from: now)
    }

    /// Дата сьогодні + n днів у форматі dd.MM.yyyy (київський час).
    static func dateOffset(_ n: Int, _ now: Date = Date()) -> String {
        let d = cal.date(byAdding: .day, value: n, to: now) ?? now
        return fmt(d, "dd.MM.yyyy")
    }

    /// Початок доби (00:00 за Києвом) для сьогодні + n днів.
    static func startOfDay(offset n: Int, _ now: Date = Date()) -> Date {
        let c = cal
        let d = c.date(byAdding: .day, value: n, to: now) ?? now
        return c.startOfDay(for: d)
    }

    /// Підтверджений графік ДТЕК на сьогодні (0) або завтра (1); nil, якщо його ще нема.
    static func factFor(_ d: SchedData, _ offset: Int, _ now: Date = Date()) -> String? {
        d.fact[dateOffset(offset, now)]
    }

    /// Склеює сусідні півгодини з однаковим станом в інтервали (у хвилинах від 0:00).
    static func intervals(_ day: String) -> [Interval] {
        let chars = Array(day)
        var cells = [Int](repeating: on, count: 48)
        for h in 0..<24 {
            let ch: Character = h < chars.count ? chars[h] : "u"
            var a = on
            var b = on
            switch ch {
            case "y": break
            case "n": a = off; b = off
            case "m": a = maybe; b = maybe
            case "f": a = off
            case "s": b = off
            case "a": a = maybe
            case "b": b = maybe
            default: a = maybe; b = maybe
            }
            cells[h * 2] = a
            cells[h * 2 + 1] = b
        }
        var out: [Interval] = []
        var start = 0
        for i in 1...48 {
            if i == 48 || cells[i] != cells[start] {
                out.append(Interval(start: start * 30, end: i * 30, state: cells[start]))
                start = i
            }
        }
        return out
    }

    /// Інтервал дня, у який потрапляє момент min (хвилини від 0:00).
    static func currentInterval(_ day: String, _ min: Int) -> Interval? {
        intervals(day).first { min >= $0.start && min < $0.end }
    }

    static func fmtTime(_ m: Int) -> String {
        "\(m / 60):" + String(format: "%02d", m % 60)
    }

    static func fmtDur(_ m: Int) -> String {
        let h = m / 60
        let mm = m % 60
        if mm == 0 { return "\(h)г" }
        if h == 0 { return "\(mm)хв" }
        return "\(h)г \(mm)хв"
    }
}
