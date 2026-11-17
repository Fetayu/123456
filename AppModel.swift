import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var addrs: [Addr] = []
    @Published var selId: String = ""
    @Published var now = Date()
    @Published var selOffset = 0
    @Published var formOpen = false
    @Published var fName = ""
    @Published var fCity = ""
    @Published var fStreet = ""
    @Published var fHouse = ""
    @Published var theme = 0
    @Published var interval = 15

    private var bag = Set<AnyCancellable>()

    init() {
        theme = Store.shared.themeMode()
        interval = Store.shared.intervalMin()
        var list = Store.shared.loadAll()
        if list.isEmpty {
            list = [Addr.new()]
            Store.shared.saveAll(list)
        }
        addrs = list
        if let s = Store.shared.selectedId(), list.contains(where: { $0.id == s }) {
            selId = s
        } else {
            selId = list[0].id
        }
        bindFields()
        formOpen = selected.isBlank

        NotificationCenter.default.publisher(for: .storeChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
            .store(in: &bag)
    }

    var selected: Addr { addrs.first { $0.id == selId } ?? addrs[0] }

    var scheme: ColorScheme? {
        switch theme {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    func reload() {
        let list = Store.shared.loadAll()
        if list.isEmpty { return }
        addrs = list
        if !list.contains(where: { $0.id == selId }) { selId = list[0].id }
    }

    func bindFields() {
        let a = selected
        fName = a.name
        fCity = a.city
        fStreet = a.street
        fHouse = a.house
    }

    func selectAddr(_ id: String) {
        if id == selId { return }
        selId = id
        Store.shared.setSelectedId(id)
        bindFields()
        formOpen = selected.isBlank
    }

    func addNew() {
        var list = Store.shared.loadAll()
        let a = Addr.new()
        list.append(a)
        Store.shared.saveAll(list)
        addrs = list
        selId = a.id
        Store.shared.setSelectedId(a.id)
        bindFields()
        formOpen = true
    }

    func deleteSelected() {
        let old = selId
        var list = Store.shared.loadAll()
        list.removeAll { $0.id == old }
        if list.isEmpty { list.append(Addr.new()) }
        Store.shared.saveAll(list)
        addrs = list
        selId = list[0].id
        Store.shared.setSelectedId(selId)
        bindFields()
        formOpen = selected.isBlank
        Notifier.planBoundaries()
    }

    /// Зберігає введені дані вибраної адреси і одразу перевіряє її.
    func saveAndCheck() {
        let id = selId
        let name = fName.trimmingCharacters(in: .whitespaces)
        let city = fCity.trimmingCharacters(in: .whitespaces)
        let street = fStreet.trimmingCharacters(in: .whitespaces)
        let house = fHouse.trimmingCharacters(in: .whitespaces)

        Store.shared.update(id) { a in
            let changed = a.city != city || a.street != street || a.house != house
            a.name = name
            a.city = city
            a.street = street
            a.house = house
            if changed {
                a.cityRes = ""
                a.streetRes = ""
                a.group = nil
                a.em = false
                a.emEnd = ""
            }
            a.stState = "none"
            a.stTitle = "Перевіряю…"
            a.stGroup = ""
            a.stDetail = ""
            a.stMeta = ""
        }
        reload()
        if !city.isEmpty && !street.isEmpty && !house.isEmpty { formOpen = false }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        Notifier.requestAuth()
        BG.schedule()
        Task { await Checker.shared.run(only: id, allowWeb: true) }
    }

    func refreshSelected() {
        let id = selId
        Task { await Checker.shared.run(only: id, allowWeb: true) }
    }

    func refreshAll() async {
        await Checker.shared.run(only: nil, allowWeb: true)
    }

    func onActive() {
        reload()
        Notifier.requestAuth()
        BG.schedule()
        let stale = Store.shared.lastCheck().map { Date().timeIntervalSince($0) > 600 } ?? true
        if stale { Task { await Checker.shared.run(only: nil, allowWeb: true) } }
        Notifier.planBoundaries()
    }

    func setTheme(_ t: Int) {
        theme = t
        Store.shared.setThemeMode(t)
    }

    func setInterval(_ m: Int) {
        interval = m
        Store.shared.setIntervalMin(m)
        BG.schedule()
    }
}

// MARK: - Підказки адрес

@MainActor
final class SuggestModel: ObservableObject {
    @Published var cities: [String] = []
    @Published var streets: [String] = []
    @Published var houses: [String] = []
    @Published var warning: String? = nil

    private var houseCache: [String: [String]] = [:]
    private var inFlight = Set<String>()
    private var warned = Set<String>()
    private var cityTask: Task<Void, Never>?
    private var houseTask: Task<Void, Never>?
    private let d = UserDefaults.standard

    private func lines(_ s: String?) -> [String] {
        guard let s = s, !s.isEmpty else { return [] }
        return s.components(separatedBy: "\n")
    }

    private func cachedCities() -> [String] { lines(d.string(forKey: "sg.cities")) }
    private func cachedStreets(_ city: String) -> [String] { lines(d.string(forKey: "sg.st:" + city.lowercased())) }

    private func resolveCity(_ list: [String], _ typed: String) -> String? {
        let cands = Set(DtekClient.candidates(typed, "а").map { $0.0.lowercased() })
        return list.first { cands.contains($0.lowercased()) }
    }

    private func warn(_ key: String, _ text: String) {
        if warned.insert(key).inserted { warning = text }
    }

    /// Викликається, коли користувач вводить місто (або торкнувся полів).
    func cityEdited(_ typedRaw: String, debounce: Bool = true) {
        cityTask?.cancel()
        cityTask = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 500_000_000) }
            if Task.isCancelled { return }
            await self?.ensureStreets(typedRaw.trimmingCharacters(in: .whitespaces))
        }
    }

    private func ensureStreets(_ typed: String) async {
        let cached = cachedCities()
        if !cached.isEmpty {
            if cities.isEmpty { cities = cached }
            if typed.count < 2 { return }
            guard let resolved = resolveCity(cached, typed) else {
                streets = []
                return
            }
            let st = cachedStreets(resolved)
            if !st.isEmpty {
                streets = st
                return
            }
        }

        let key = "dir:" + typed.lowercased()
        if !inFlight.insert(key).inserted { return }
        defer { inFlight.remove(key) }
        do {
            var targets: [String] = []
            for c in DtekClient.candidates(typed.isEmpty ? "а" : typed, "а").map({ $0.0 }) where !targets.contains(c) {
                targets.append(c)
            }
            let dir = try await DtekClient(allowWeb: true).directory(targets: targets)
            if dir.cities.isEmpty {
                warn(key, "Довідник адрес ДТЕК порожній")
                return
            }
            d.set(dir.cities.joined(separator: "\n"), forKey: "sg.cities")
            if !dir.city.isEmpty && !dir.streets.isEmpty {
                d.set(dir.streets.joined(separator: "\n"), forKey: "sg.st:" + dir.city.lowercased())
            }
            cities = dir.cities
            if !dir.streets.isEmpty {
                streets = dir.streets
            } else if typed.count >= 2 {
                warn(key, "Міста «\(typed)» немає у списку ДТЕК")
            }
        } catch is CancellationError {
            return
        } catch {
            warn(key, "Підказки недоступні: " + Checker.describe(error))
        }
    }

    func streetEdited(city: String, street: String) {
        houseTask?.cancel()
        houseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            await self?.loadHouses(city: city.trimmingCharacters(in: .whitespaces),
                                   street: street.trimmingCharacters(in: .whitespaces))
        }
    }

    private func houseOrder(_ s: String) -> Int {
        let digits = s.prefix { $0.isNumber }
        return Int(digits) ?? Int.max
    }

    private func loadHouses(city: String, street: String) async {
        if city.count < 2 || street.count < 3 { return }
        let key = (city + "|" + street).lowercased()
        if let c = houseCache[key] {
            houses = c
            return
        }
        if !inFlight.insert("h:" + key).inserted { return }
        defer { inFlight.remove("h:" + key) }
        do {
            let list = try await DtekClient(allowWeb: true).houses(pairs: DtekClient.candidates(city, street))
            if !list.isEmpty {
                let sorted = list.sorted { a, b in
                    let oa = houseOrder(a), ob = houseOrder(b)
                    return oa != ob ? oa < ob : a < b
                }
                houseCache[key] = sorted
                houses = sorted
            }
        } catch is CancellationError {
            return
        } catch {
            warn("h:" + key, "Підказки будинків недоступні: " + Checker.describe(error))
        }
    }
}
