import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Стан для великої картки

struct StatusInfo {
    var state: String
    var title: String
    var detail: String
    var until: (String, String)?
}

enum StatusLogic {
    static func remainText(_ mins: Int) -> String {
        if mins <= 0 { return "Час минув, чекаємо нових даних від ДТЕК" }
        if mins >= 60 { return "ще ≈ \(mins / 60) год \(mins % 60) хв" }
        return "ще ≈ \(mins) хв"
    }

    /// "до коли" і "скільки лишилось" за часом відновлення, який вказав ДТЕК.
    static func untilTexts(_ end: String, _ now: Date) -> (String, String)? {
        let e = end.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return nil }
        guard let d = Sched.parse(e, "HH:mm dd.MM.yyyy") else { return nil }
        let parts = e.split(separator: " ").map(String.init)
        let today = Sched.fmt(now, "dd.MM.yyyy")
        let date = parts.count >= 2 ? parts[1] : ""
        let shown = (date == today || date.isEmpty)
            ? "Орієнтовно до \(parts[0])"
            : "Орієнтовно до \(parts[0]), \(date.prefix(5))"
        let mins = Int(d.timeIntervalSince(now) / 60)
        return (shown, remainText(mins))
    }

    static func compute(_ a: Addr, _ now: Date) -> StatusInfo {
        let nowMin = Sched.nowMinutes(now)
        var schedNow: Interval? = nil
        if let d = a.sched, let slots = Sched.factFor(d, 0, now) {
            schedNow = Sched.currentInterval(slots, nowMin)
        }

        var state = a.stState
        var title = a.stTitle.isEmpty ? "Додайте адресу" : a.stTitle
        var detail = a.stDetail
        var until: (String, String)? = a.stState == "off" ? untilTexts(a.emEnd, now) : nil

        if a.stState == "ok", let iv = schedNow {
            if iv.state == Sched.off {
                state = "off"
                title = "За графіком світла немає"
                detail = "Відключення за графіком ДТЕК: \(Sched.fmtTime(iv.start)) - \(Sched.fmtTime(iv.end)).\n" +
                         "На сайті ще не підтвердили: дані там оновлюються із затримкою."
                until = ("Орієнтовно до \(Sched.fmtTime(iv.end))", remainText(iv.end - nowMin))
            } else if iv.state == Sched.maybe {
                detail = a.stDetail + "\nМожливе відключення за графіком: \(Sched.fmtTime(iv.start)) - \(Sched.fmtTime(iv.end))"
            }
        }
        return StatusInfo(state: state, title: title, detail: detail, until: until)
    }

    /// bg1, bg2, текст
    static func palette(_ state: String, night: Bool) -> (Color, Color, Color) {
        switch state {
        case "ok":
            return night ? (Color(hex: 0x173D26), Color(hex: 0x0E2618), Color(hex: 0xCFF1D8))
                         : (Color(hex: 0xEAF7EE), Color(hex: 0xD3EFDB), Color(hex: 0x0F3D22))
        case "off":
            return night ? (Color(hex: 0x4D1B17), Color(hex: 0x30100E), Color(hex: 0xFFD9D3))
                         : (Color(hex: 0xFDEBE8), Color(hex: 0xF8D0CA), Color(hex: 0x7A1B14))
        case "error":
            return night ? (Color(hex: 0x4A3812), Color(hex: 0x30240A), Color(hex: 0xFFE6B3))
                         : (Color(hex: 0xFFF6E3), Color(hex: 0xFFE7B3), Color(hex: 0x6B4300))
        default:
            return night ? (Color(hex: 0x2D313B), Color(hex: 0x1E2128), Color(hex: 0xE6E8EE))
                         : (Color(hex: 0xF1F3F8), Color(hex: 0xE2E6F0), Color(hex: 0x1F2430))
        }
    }
}

// MARK: - Головна

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var suggest = SuggestModel()
    @Environment(\.colorScheme) private var scheme
    @State private var showSettings = false
    @State private var confirmDelete = false

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var night: Bool { scheme == .dark }
    private var cardBg: Color { night ? Color(hex: 0x141418) : Color(.secondarySystemGroupedBackground) }

    var body: some View {
        ZStack {
            (night ? Color(hex: 0x050507) : Color(.systemGroupedBackground)).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    chips
                    StatusCard(addr: model.selected, now: model.now, night: night) {
                        model.refreshSelected()
                    }
                    ScheduleCard(addr: model.selected, now: model.now, night: night, cardBg: cardBg)
                    addressCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .refreshable { await model.refreshAll() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(model.scheme)
        }
        .onReceive(timer) { _ in model.now = Date() }
        .confirmationDialog("Видалити адресу?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Видалити", role: .destructive) { model.deleteSelected() }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text(model.selected.label)
        }
    }

    private var header: some View {
        HStack {
            Text("Світло")
                .font(.system(size: 32, weight: .bold))
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.top, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.addrs) { a in
                    let sel = a.id == model.selId
                    Button {
                        model.selectAddr(a.id)
                    } label: {
                        Text(a.label)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(sel ? Color(hex: 0xFFD60A) : Color.primary.opacity(0.08)))
                            .foregroundColor(sel ? Color(hex: 0x1A1A1A) : .primary)
                    }
                }
                Button {
                    model.addNew()
                } label: {
                    Text("＋ Додати")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        .foregroundColor(.primary)
                }
            }
        }
    }

    private var addressCard: some View {
        let a = model.selected
        let summary: String = {
            if a.isBlank { return "Адреса не задана" }
            let city = a.cityRes.isEmpty ? a.city : a.cityRes
            let street = a.streetRes.isEmpty ? a.street : a.streetRes
            return "\(city), \(street), \(a.house)"
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("АДРЕСА")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(summary)
                        .font(.system(size: 16))
                }
                Spacer()
                Button(model.formOpen ? "Сховати" : "Змінити") {
                    model.formOpen.toggle()
                }
                .buttonStyle(.bordered)
            }

            if model.formOpen {
                VStack(spacing: 10) {
                    TextField("Назва (необов'язково)", text: $model.fName)
                        .textFieldStyle(.roundedBorder)

                    SuggestField(title: "Місто", text: $model.fCity, options: suggest.cities) {
                        suggest.cityEdited(model.fCity)
                    } onFocus: {
                        suggest.cityEdited(model.fCity, debounce: false)
                    }

                    SuggestField(title: "Вулиця", text: $model.fStreet, options: suggest.streets) {
                        suggest.streetEdited(city: model.fCity, street: model.fStreet)
                    } onFocus: {
                        suggest.cityEdited(model.fCity, debounce: false)
                    }

                    SuggestField(title: "Номер будинку", text: $model.fHouse, options: suggest.houses) {
                    } onFocus: {
                        suggest.streetEdited(city: model.fCity, street: model.fStreet)
                    }

                    if let w = suggest.warning {
                        Text(w)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        model.saveAndCheck()
                    } label: {
                        Text("Зберегти і перевірити")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFFD60A)))
                            .foregroundColor(Color(hex: 0x1A1A1A))
                    }

                    Button("Видалити цю адресу", role: .destructive) {
                        confirmDelete = true
                    }
                    .font(.system(size: 15))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 24).fill(cardBg))
    }
}

// MARK: - Поле з підказками

struct SuggestField: View {
    let title: String
    @Binding var text: String
    let options: [String]
    var onEdit: () -> Void
    var onFocus: () -> Void
    @FocusState private var focused: Bool

    private var filtered: [String] {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let base = t.isEmpty ? options : options.filter { $0.lowercased().contains(t) }
        return Array(base.filter { $0.lowercased() != t }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disableAutocorrection(true)
                .onChange(of: text) { _ in
                    if focused { onEdit() }
                }
                .onChange(of: focused) { f in
                    if f { onFocus() }
                }
            if focused && !filtered.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { s in
                        Button {
                            text = s
                        } label: {
                            Text(s)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                        }
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            }
        }
    }
}

// MARK: - Велика картка стану

struct StatusCard: View {
    let addr: Addr
    let now: Date
    let night: Bool
    let onTap: () -> Void

    var body: some View {
        let info = StatusLogic.compute(addr, now)
        let (c0, c1, fg) = StatusLogic.palette(info.state, night: night)
        let faint = fg.opacity(0.15)
        let empty = addr.stState == "none" && addr.stTitle.isEmpty
        let shownDetail = empty
            ? "Натисніть «Змінити» нижче і введіть місто, вулицю та номер будинку."
            : info.detail
        let icon: String = {
            switch info.state {
            case "ok": return "💡"
            case "off": return "🔌"
            case "error": return "⚠️"
            default: return "🏠"
            }
        }()

        return Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(icon).font(.system(size: 40))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(addr.label.uppercased())
                            .font(.system(size: 12, weight: .medium))
                            .opacity(0.8)
                        if !addr.stGroup.isEmpty {
                            Text(addr.stGroup)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(faint))
                        }
                    }
                    Spacer()
                }

                Text(info.title)
                    .font(.system(size: 36, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)

                if let u = info.until {
                    Text(u.0).font(.system(size: 20, weight: .medium))
                    Text(u.1).font(.system(size: 15)).opacity(0.85)
                }

                if !shownDetail.isEmpty {
                    Text(shownDetail)
                        .font(.system(size: 16))
                        .multilineTextAlignment(.leading)
                }

                if !addr.stMeta.isEmpty {
                    Rectangle().fill(faint).frame(height: 1)
                    Text(addr.stMeta)
                        .font(.system(size: 12))
                        .opacity(0.8)
                        .multilineTextAlignment(.leading)
                }

                if !empty {
                    Text("↻ Торкніться, щоб оновити")
                        .font(.system(size: 11))
                        .opacity(0.7)
                }
            }
            .foregroundColor(fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(LinearGradient(colors: [c0, c1], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Тижневий графік

struct ScheduleCard: View {
    @EnvironmentObject var model: AppModel
    let addr: Addr
    let now: Date
    let night: Bool
    let cardBg: Color

    private var accentText: Color { night ? Color(hex: 0xFFD60A) : Color(hex: 0x8A6500) }

    var body: some View {
        if let data = addr.sched {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("ГРАФІК ВІДКЛЮЧЕНЬ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Група " + data.groupId.replacingOccurrences(of: #"^\D+"#, with: "", options: .regularExpression))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 6) {
                    dayTab(0, "Сьогодні " + String(Sched.dateOffset(0, now).prefix(5)))
                    dayTab(1, "Завтра " + String(Sched.dateOffset(1, now).prefix(5)))
                }

                if !data.updated.isEmpty {
                    Text("Оновлено ДТЕК: " + data.updated)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                content(data)
                legend
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 24).fill(cardBg))
        }
    }

    private func dayTab(_ i: Int, _ title: String) -> some View {
        let sel = model.selOffset == i
        return Button {
            model.selOffset = i
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule().fill(sel ? Color(hex: 0xFFD60A) : Color.primary.opacity(0.08)))
                .foregroundColor(sel ? Color(hex: 0x1A1A1A) : .primary)
        }
    }

    @ViewBuilder
    private func content(_ data: SchedData) -> some View {
        if let slots = Sched.factFor(data, model.selOffset, now) {
            let nowMin = Sched.nowMinutes(now)
            VStack(spacing: 0) {
                ForEach(Array(Sched.intervals(slots).enumerated()), id: \.offset) { _, iv in
                    let isNow = model.selOffset == 0 && nowMin >= iv.start && nowMin < iv.end
                    intervalRow(iv, isNow)
                }
            }
        } else {
            let text: String = {
                if data.factKeys > 0 && data.fact.isEmpty {
                    return "Не вдалося прочитати графік. Відкрийте «Діагностика» в налаштуваннях."
                }
                if model.selOffset == 0 { return "Графік на сьогодні ще не опубліковано." }
                return "Інформація від НЕК «Укренерго» про обмеження на наступний день ще не надходила."
            }()
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(night ? Color(hex: 0xFFE680) : Color(hex: 0x5C4A00))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(night ? Color(hex: 0xFFD60A, opacity: 0.2) : Color(hex: 0xFFF4C2)))
        }
    }

    private func intervalRow(_ iv: Interval, _ isNow: Bool) -> some View {
        let color: Color = iv.state == Sched.on ? accentText : .secondary
        let bold = iv.state == Sched.on || isNow
        return HStack {
            Group {
                switch iv.state {
                case Sched.off: Image(systemName: "bolt.slash")
                case Sched.maybe: Image(systemName: "exclamationmark.circle")
                default: Image(systemName: "bolt").opacity(0)
                }
            }
            .frame(width: 22, height: 22)
            .foregroundColor(.secondary)

            Text("\(Sched.fmtTime(iv.start)) - \(Sched.fmtTime(iv.end))")
                .font(.system(size: 17, weight: bold ? .semibold : .regular))
                .foregroundColor(color)
                .frame(maxWidth: .infinity)

            Text(Sched.fmtDur(iv.end - iv.start))
                .font(.system(size: 15))
                .foregroundColor(color)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(isNow ? Color.primary.opacity(0.08) : Color.clear))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundColor(.secondary)
                Text("Можливе відключення")
            }
            HStack(spacing: 8) {
                Image(systemName: "bolt.slash").foregroundColor(.secondary)
                Text("Відключення світла")
            }
            HStack(spacing: 8) {
                Text("●").foregroundColor(accentText)
                Text("Світло є")
            }
        }
        .font(.system(size: 14))
        .foregroundColor(.secondary)
        .padding(.top, 4)
    }
}

// MARK: - Налаштування

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showRaw = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("ТЕМА")
                    Picker("Тема", selection: Binding(get: { model.theme }, set: { model.setTheme($0) })) {
                        Text("Авто").tag(0)
                        Text("Світла").tag(1)
                        Text("Темна").tag(2)
                    }
                    .pickerStyle(.segmented)

                    section("КОЛИ ПЕРЕВІРЯТИ ДТЕК")
                    Picker("Інтервал", selection: Binding(get: { model.interval }, set: { model.setInterval($0) })) {
                        Text("15 хв").tag(15)
                        Text("30 хв").tag(30)
                        Text("1 год").tag(60)
                        Text("3 год").tag(180)
                    }
                    .pickerStyle(.segmented)

                    Text("Додаток питає сайт ДТЕК у фоні, коли iOS це дозволяє. Систему не змусити: вона сама вирішує, як часто будити додаток (зазвичай рідше, ніж просите), а іноді не будить зовсім. Сповіщення про вмикання і вимикання за графіком приходять точно вчасно, а аварійні відключення додаток побачить, коли iOS дасть фон або коли ви його відкриєте.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    Text(Store.shared.trafficText())
                        .font(.system(size: 13))

                    Button {
                        if let u = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(u)
                        }
                    } label: {
                        Text("Налаштування iPhone: сповіщення і фонове оновлення")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    DisclosureGroup("Діагностика", isExpanded: $showRaw) {
                        Text(String(model.selected.raw.prefix(3500)))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .navigationTitle("Налаштування")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func section(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.top, 6)
    }
}
