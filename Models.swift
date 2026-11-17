import Foundation

struct Parsed {
    var groups: String
    var emergency: Bool
    var reason: String
    var start: String
    var end: String
    var updated: String
    var groupId: String
}

struct FetchResult {
    var raw: String
    var city: String
    var street: String
}

struct Interval: Equatable {
    var start: Int
    var end: Int
    var state: Int
}

/// Тижневий графік. Кожен день - рядок із 24 символів (по одному на годину):
/// y - світло є, n - немає, m - можливе відключення,
/// f / s - немає перші / другі 30 хв, a / b - можливо немає перші / другі 30 хв.
struct SchedData: Codable, Equatable {
    var groupId: String
    var preset: [String]
    var fact: [String: String]
    var updated: String
    var factKeys: Int
}

/// Одна збережена адреса разом з останнім результатом перевірки.
struct Addr: Codable, Identifiable, Equatable {
    var id: String
    var name = ""
    var city = ""
    var street = ""
    var house = ""
    var cityRes = ""
    var streetRes = ""
    var group: String? = nil
    var em = false
    var emEnd = ""
    var stState = "none"      // ok / off / error / none
    var stTitle = ""
    var stGroup = ""
    var stDetail = ""
    var stMeta = ""
    var sched: SchedData? = nil
    var raw = ""

    var label: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if !street.trimmingCharacters(in: .whitespaces).isEmpty {
            return (street + " " + house).trimmingCharacters(in: .whitespaces)
        }
        return "Нова адреса"
    }

    var isBlank: Bool {
        city.trimmingCharacters(in: .whitespaces).isEmpty ||
        street.trimmingCharacters(in: .whitespaces).isEmpty ||
        house.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func new() -> Addr { Addr(id: UUID().uuidString) }
}

struct DtekError: LocalizedError {
    let message: String
    var needsWeb = false

    init(_ message: String, needsWeb: Bool = false) {
        self.message = message
        self.needsWeb = needsWeb
    }

    var errorDescription: String? { message }
}

extension Notification.Name {
    static let storeChanged = Notification.Name("svitlo.store.changed")
}
