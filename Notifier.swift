import Foundation
import UserNotifications
import BackgroundTasks

final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

enum Notifier {
    static func setup() {
        UNUserNotificationCenter.current().delegate = NotifDelegate.shared
    }

    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Сповіщення одразу (однаковий id замінює попереднє).
    static func show(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Планує сповіщення на моменти, коли за підтвердженим графіком світло зникає або з'являється
    /// (сьогодні і завтра, для всіх адрес). iOS показує їх сама, навіть коли додаток закритий.
    static func planBoundaries() {
        let center = UNUserNotificationCenter.current()
        let addrs = Store.shared.loadAll()
        let multi = addrs.count > 1
        let now = Date()

        var planned: [(Date, UNNotificationRequest)] = []

        for a in addrs {
            guard let d = a.sched, !a.isBlank else { continue }
            let who = multi ? a.label + ": " : ""

            for offset in 0...1 {
                guard let day = Sched.factFor(d, offset, now) else { continue }
                let dayStart = Sched.startOfDay(offset: offset, now)
                let ivs = Sched.intervals(day)

                // стан наприкінці попередньої доби (для півночі), якщо графік на неї є
                var prevOff: Bool? = nil
                if offset == 1, let today = Sched.factFor(d, 0, now), let last = Sched.intervals(today).last {
                    prevOff = last.state == Sched.off
                }

                for (i, iv) in ivs.enumerated() {
                    let isOff = iv.state == Sched.off
                    var before: Bool? = prevOff
                    if i > 0 { before = ivs[i - 1].state == Sched.off }
                    guard let was = before, was != isOff else { continue }

                    let fire = dayStart.addingTimeInterval(Double(iv.start * 60 + 5))
                    if fire.timeIntervalSince(now) < 3 { continue }

                    let title: String
                    let body: String
                    if isOff {
                        title = who + "За графіком світла немає"
                        body = "Відключення \(Sched.fmtTime(iv.start)) - \(Sched.fmtTime(iv.end)). Світло орієнтовно повернеться о \(Sched.fmtTime(iv.end)). На сайті ДТЕК це може з'явитися із затримкою."
                    } else {
                        title = who + "За графіком світло має бути"
                        body = "Відключення за графіком закінчилось."
                    }
                    let c = UNMutableNotificationContent()
                    c.title = title
                    c.body = body
                    c.sound = .default
                    let trig = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSince(now), repeats: false)
                    let rid = "b|\(a.id)|\(Sched.dateOffset(offset, now))|\(iv.start)"
                    planned.append((fire, UNNotificationRequest(identifier: rid, content: c, trigger: trig)))
                }
            }
        }

        planned.sort { $0.0 < $1.0 }
        let toAdd = planned.prefix(60).map { $0.1 }

        center.getPendingNotificationRequests { pending in
            let old = pending.map { $0.identifier }.filter { $0.hasPrefix("b|") }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for r in toAdd { center.add(r) }
        }
    }
}

/// Фонові оновлення iOS (система сама вирішує, коли їх запускати).
enum BG {
    static let id = "com.example.svet.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let t = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            schedule()
            let work = Task {
                await Checker.shared.run(only: nil, allowWeb: false)
                t.setTaskCompleted(success: true)
            }
            t.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: id)
        req.earliestBeginDate = Date(timeIntervalSinceNow: Double(Store.shared.intervalMin()) * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}
