import Foundation

/// Перевірка адрес на сайті ДТЕК. Запуски йдуть по черзі, щоб не плутати збережені дані.
actor Checker {
    static let shared = Checker()
    private var last: Task<Void, Never>?

    func run(only id: String?, allowWeb: Bool) async {
        let prev = last
        let t = Task {
            await prev?.value
            await Checker.work(only: id, allowWeb: allowWeb)
        }
        last = t
        await t.value
    }

    private static func work(only: String?, allowWeb: Bool) async {
        let ids: [String] = only.map { [$0] } ?? Store.shared.loadAll().map { $0.id }
        for id in ids {
            if Task.isCancelled { break }
            await checkOne(id, allowWeb: allowWeb)
        }
        Store.shared.setLastCheck(Date())
        Notifier.planBoundaries()
    }

    static func describe(_ e: Error) -> String {
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "немає інтернету"
            case .timedOut: return "сайт ДТЕК не відповів вчасно"
            default: return u.localizedDescription
            }
        }
        return e.localizedDescription
    }

    private static func isCancel(_ e: Error) -> Bool {
        e is CancellationError || (e as? URLError)?.code == .cancelled
    }

    private static func nowText() -> String { Sched.fmt(Date(), "HH:mm dd.MM") }

    private static func checkOne(_ id: String, allowWeb: Bool) async {
        let store = Store.shared
        guard let a0 = store.loadAll().first(where: { $0.id == id }) else { return }

        if a0.isBlank {
            store.update(id) { a in
                a.stState = "none"
                a.stTitle = "Додайте адресу"
                a.stGroup = ""
                a.stDetail = "Введіть місто, вулицю і номер будинку."
                a.stMeta = ""
            }
            return
        }

        let city = a0.city, street = a0.street, house = a0.house
        let who = store.loadAll().count > 1 ? a0.label + ": " : ""
        let resolved = !a0.cityRes.isEmpty && !a0.streetRes.isEmpty
        let pairs: [(String, String)] = resolved
            ? [(a0.cityRes, a0.streetRes)]
            : DtekClient.candidates(city, street)

        /// Адреса досі та сама (користувач не змінив її, поки йшла перевірка).
        func stillSame() -> Bool {
            store.loadAll().contains { $0.id == id && $0.city == city && $0.street == street && $0.house == house }
        }

        let client = DtekClient(allowWeb: allowWeb)

        let fr: FetchResult
        do {
            fr = try await client.fetch(pairs: pairs)
        } catch {
            store.addTraffic(client.bytes)
            if isCancel(error) { return }
            guard stillSame() else { return }
            let msg = describe(error)
            store.update(id) { a in
                a.stState = "error"
                a.stTitle = "Не вдалося перевірити"
                a.stGroup = ""
                a.stDetail = msg
                a.stMeta = "Перевірено: " + nowText()
                if resolved { a.cityRes = ""; a.streetRes = "" }
            }
            return
        }
        store.addTraffic(client.bytes)
        guard stillSame() else { return }

        guard let cur = store.loadAll().first(where: { $0.id == id }) else { return }

        let r: Parsed
        do {
            r = try DtekClient.parse(fr.raw, house: house)
        } catch {
            let msg = describe(error)
            store.update(id) { a in
                a.raw = String(fr.raw.prefix(3000))
                a.cityRes = fr.city
                a.streetRes = fr.street
                a.stState = "error"
                a.stTitle = "Не вдалося розібрати відповідь"
                a.stGroup = ""
                a.stDetail = msg
                a.stMeta = "Перевірено: " + nowText()
            }
            return
        }

        // сповіщення про зміни
        if let g = cur.group, g != r.groups {
            Notifier.show(id: "grp-\(id)", title: who + "ДТЕК змінив групу", body: "Було \(g), тепер \(r.groups)")
        }
        if r.emergency && !cur.em {
            Notifier.show(id: "em-\(id)", title: who + "Світла немає",
                          body: "\(r.reason). З \(r.start). Світло орієнтовно повернуть до \(r.end)")
        } else if r.emergency && cur.em && r.end != cur.emEnd {
            Notifier.show(id: "em-\(id)", title: who + "Змінився час відновлення",
                          body: "Світло орієнтовно повернуть до \(r.end)")
        } else if !r.emergency && cur.em {
            Notifier.show(id: "off-\(id)", title: who + "Світло має бути",
                          body: "ДТЕК більше не показує відключення за цією адресою")
        }

        let sched = Sched.build(raw: fr.raw, groupId: r.groupId) ?? cur.sched
        let diag = Sched.diag(fr.raw)
        let groupText = r.groups.contains(",") ? "Групи \(r.groups)" : "Група \(r.groups)"
        let meta = "\(fr.city), \(fr.street), \(house)\nДані сайту: \(r.updated)  ·  Перевірено: \(nowText())"

        store.update(id) { a in
            a.raw = diag
            a.sched = sched
            a.cityRes = fr.city
            a.streetRes = fr.street
            a.group = r.groups
            a.em = r.emergency
            a.emEnd = r.end
            a.stGroup = groupText
            a.stMeta = meta
            if r.emergency {
                let reason = r.reason.trimmingCharacters(in: .whitespaces).isEmpty ? "Причина не вказана" : r.reason
                a.stState = "off"
                a.stTitle = "Світла немає"
                a.stDetail = "\(reason)\nВідключення з \(r.start)"
            } else {
                a.stState = "ok"
                a.stTitle = "Світло є"
                a.stDetail = "Відключення зараз немає"
            }
        }
    }
}
