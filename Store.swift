import Foundation

/// Сховище: адреси, налаштування, лічильник трафіку. Усе в UserDefaults.
final class Store {
    static let shared = Store()

    private let lock = NSLock()
    private let d = UserDefaults.standard

    // MARK: - адреси

    func loadAll() -> [Addr] {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [Addr] {
        guard let data = d.data(forKey: "addrs"),
              let list = try? JSONDecoder().decode([Addr].self, from: data) else { return [] }
        return list
    }

    func saveAll(_ list: [Addr]) {
        lock.lock()
        saveUnlocked(list)
        lock.unlock()
        notifyChanged()
    }

    private func saveUnlocked(_ list: [Addr]) {
        if let data = try? JSONEncoder().encode(list) {
            d.set(data, forKey: "addrs")
        }
    }

    /// Атомарно змінює одну адресу. Повертає false, якщо такої адреси вже нема.
    @discardableResult
    func update(_ id: String, _ block: (inout Addr) -> Void) -> Bool {
        lock.lock()
        var list = loadUnlocked()
        guard let i = list.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        block(&list[i])
        saveUnlocked(list)
        lock.unlock()
        notifyChanged()
        return true
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .storeChanged, object: nil)
        }
    }

    func selectedId() -> String? { d.string(forKey: "sel") }
    func setSelectedId(_ id: String) { d.set(id, forKey: "sel") }

    // MARK: - налаштування

    /// 0 - авто, 1 - світла, 2 - темна
    func themeMode() -> Int { d.integer(forKey: "theme") }
    func setThemeMode(_ m: Int) { d.set(m, forKey: "theme") }

    /// Як часто (у хвилинах) просимо iOS перевіряти ДТЕК у фоні.
    func intervalMin() -> Int {
        let v = d.integer(forKey: "interval")
        return v == 0 ? 15 : v
    }
    func setIntervalMin(_ m: Int) { d.set(m, forKey: "interval") }

    func lastCheck() -> Date? {
        let t = d.double(forKey: "lastCheck")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func setLastCheck(_ date: Date) { d.set(date.timeIntervalSince1970, forKey: "lastCheck") }

    // MARK: - трафік

    private func fmtBytes(_ b: Int) -> String {
        if b < 1024 * 1024 { return "\(max(1, b / 1024)) КБ" }
        return String(format: "%.1f МБ", Double(b) / 1048576.0).replacingOccurrences(of: ".", with: ",")
    }

    private func todayKey() -> String { Sched.fmt(Date(), "yyyy-MM-dd") }

    /// Запам'ятовує, скільки інтернету витратила остання перевірка.
    func addTraffic(_ bytes: Int) {
        if bytes <= 0 { return }
        lock.lock(); defer { lock.unlock() }
        let day = todayKey()
        let prev = d.string(forKey: "trDay") == day ? d.integer(forKey: "trTotal") : 0
        d.set(day, forKey: "trDay")
        d.set(prev + bytes, forKey: "trTotal")
        d.set(bytes, forKey: "trLast")
    }

    func trafficText() -> String {
        let last = d.integer(forKey: "trLast")
        let today = d.string(forKey: "trDay") == todayKey() ? d.integer(forKey: "trTotal") : 0
        if last <= 0 && today <= 0 { return "Витрата інтернету з'явиться після першої перевірки." }
        let perDay = 1440 / max(1, intervalMin())
        let addrCount = max(1, loadAll().filter { !$0.isBlank }.count)
        let estimate = last * perDay * addrCount
        return "Остання перевірка: ≈ \(fmtBytes(last))\n" +
               "Сьогодні вже: ≈ \(fmtBytes(today))\n" +
               "Якби перевірки йшли з таким інтервалом: ≈ \(fmtBytes(estimate)) на добу"
    }
}
