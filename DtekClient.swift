import Foundation
import WebKit

enum Dtek {
    static let host = "https://www.dtek-dnem.com.ua"
    static let page = host + "/ua/shutdowns"
    static let ajax = host + "/ua/ajax"
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}

/// Спосіб надіслати POST на /ua/ajax з токеном сторінки.
protocol AjaxTransport: AnyObject {
    func post(_ fields: [(String, String)]) async throws -> String
    func cityOptions() async throws -> [String]
}

// MARK: - Звичайні запити (працюють і у фоні)

final class URLTransport: AjaxTransport {
    private let session: URLSession
    private var csrf: String?
    private var html = ""
    private(set) var bytes = 0

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 25
        cfg.httpAdditionalHeaders = [
            "User-Agent": Dtek.userAgent,
            "Accept-Language": "uk-UA,uk;q=0.9"
        ]
        session = URLSession(configuration: cfg)
    }

    private static let asciiSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ fields: [(String, String)]) -> String {
        fields.map { f in
            let k = f.0.addingPercentEncoding(withAllowedCharacters: asciiSafe) ?? ""
            let v = f.1.addingPercentEncoding(withAllowedCharacters: asciiSafe) ?? ""
            return k + "=" + v
        }.joined(separator: "&")
    }

    private static func extractCsrf(_ html: String) -> String? {
        let patterns = [
            #"<meta[^>]+name=["']csrf-token["'][^>]*content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]*name=["']csrf-token["']"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = html as NSString
            if let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    private func loadPage() async throws {
        var req = URLRequest(url: URL(string: Dtek.page)!)
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        bytes += data.count
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw DtekError("сайт ДТЕК відповів кодом \(code)", needsWeb: true)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let t = Self.extractCsrf(text) else {
            throw DtekError("на сторінці ДТЕК немає токена", needsWeb: true)
        }
        html = text
        csrf = t
    }

    func post(_ fields: [(String, String)]) async throws -> String {
        if csrf == nil { try await loadPage() }
        var req = URLRequest(url: URL(string: Dtek.ajax)!)
        req.httpMethod = "POST"
        req.setValue(csrf ?? "", forHTTPHeaderField: "X-CSRF-Token")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(Dtek.page, forHTTPHeaderField: "Referer")
        req.setValue(Dtek.host, forHTTPHeaderField: "Origin")
        req.httpBody = Self.encode(fields).data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        bytes += data.count
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 || code == 419 {
            csrf = nil
            throw DtekError("сайт ДТЕК відхилив запит (код \(code))", needsWeb: true)
        }
        let text = String(decoding: data, as: UTF8.self)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(t.hasPrefix("{") || t.hasPrefix("[")) {
            throw DtekError("відповідь сайту не схожа на дані", needsWeb: true)
        }
        return text
    }

    func cityOptions() async throws -> [String] {
        if csrf == nil { try await loadPage() }
        var out: [String] = []
        if let selRe = try? NSRegularExpression(
            pattern: #"<select[^>]*name=["']city["'][^>]*>(.*?)</select>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let optRe = try? NSRegularExpression(
            pattern: #"<option[^>]*>(.*?)</option>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = html as NSString
            if let m = selRe.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                let block = ns.substring(with: m.range(at: 1)) as NSString
                for o in optRe.matches(in: block as String, range: NSRange(location: 0, length: block.length)) {
                    var t = block.substring(with: o.range(at: 1))
                    t = t.replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&#039;", with: "'")
                        .replacingOccurrences(of: "&apos;", with: "'")
                    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty && !t.contains("Оберіть") { out.append(t) }
                }
            }
        }
        if out.isEmpty { throw DtekError("список міст не знайдено у коді сторінки", needsWeb: true) }
        return out
    }
}

// MARK: - Запити через справжній браузер (запасний варіант, лише коли додаток відкритий)

@MainActor
final class WebTransport: NSObject, AjaxTransport, WKNavigationDelegate {
    private var web: WKWebView?
    private var loaded = false
    private var navCont: CheckedContinuation<Void, Error>?

    private func finishNav(_ r: Result<Void, Error>) {
        guard let c = navCont else { return }
        navCont = nil
        switch r {
        case .success: c.resume()
        case .failure(let e): c.resume(throwing: e)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNav(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNav(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNav(.failure(error))
    }

    private func ensureLoaded() async throws {
        if loaded { return }
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: WKWebViewConfiguration())
        w.customUserAgent = Dtek.userAgent
        w.navigationDelegate = self
        web = w
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navCont = c
            w.load(URLRequest(url: URL(string: Dtek.page)!))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                self?.finishNav(.failure(DtekError("таймаут завантаження сторінки ДТЕК")))
            }
        }
        for _ in 0..<30 {
            let r = try? await w.callAsyncJavaScript(
                "return !!document.querySelector('meta[name=\"csrf-token\"]');",
                arguments: [:], in: nil, contentWorld: .page)
            if (r as? Bool) == true {
                loaded = true
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw DtekError("сторінка ДТЕК не віддала токен (можливо, потрібна перевірка в браузері)")
    }

    func post(_ fields: [(String, String)]) async throws -> String {
        try await ensureLoaded()
        let arr: [[String]] = fields.map { [$0.0, $0.1] }
        let body = """
        const m = document.querySelector('meta[name="csrf-token"]');
        if (!m) { return 'ERR:no-csrf'; }
        const b = new URLSearchParams();
        for (const f of fields) { b.append(f[0], f[1]); }
        const r = await fetch('/ua/ajax', {
          method: 'POST',
          credentials: 'same-origin',
          headers: {
            'X-CSRF-Token': m.content,
            'X-Requested-With': 'XMLHttpRequest',
            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'
          },
          body: b.toString()
        });
        return await r.text();
        """
        let res = try await web!.callAsyncJavaScript(body, arguments: ["fields": arr], in: nil, contentWorld: .page)
        let s = (res as? String) ?? ""
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(t.hasPrefix("{") || t.hasPrefix("[")) {
            throw DtekError("відповідь сайту не схожа на дані: " + String(s.prefix(120)))
        }
        return s
    }

    func cityOptions() async throws -> [String] {
        try await ensureLoaded()
        let body = """
        const sel = document.querySelector('select[name="city"]') ||
                    document.querySelector('#city') ||
                    document.querySelector('[data-name="city"]');
        const out = [];
        if (sel && sel.options) {
          for (let i = 0; i < sel.options.length; i++) {
            const v = sel.options[i].text || sel.options[i].value;
            if (v && v.trim() && v.indexOf('Оберіть') === -1) out.push(v.trim());
          }
        }
        return out;
        """
        let res = try await web!.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        let list = (res as? [String]) ?? []
        return list
    }
}

// MARK: - Клієнт

struct Dir {
    var cities: [String]
    var city: String
    var streets: [String]
}

final class DtekClient {
    private let allowWeb: Bool
    private let urlT = URLTransport()
    private var webT: WebTransport?
    private var useWeb = false

    init(allowWeb: Bool) { self.allowWeb = allowWeb }

    /// Скільки байтів завантажено звичайними запитами.
    var bytes: Int { urlT.bytes }

    private func web() async -> WebTransport {
        if let w = webT { return w }
        let w = await MainActor.run { WebTransport() }
        webT = w
        return w
    }

    private func post(_ fields: [(String, String)]) async throws -> String {
        if !useWeb {
            do {
                return try await urlT.post(fields)
            } catch let e as DtekError where e.needsWeb {
                guard allowWeb else { throw e }
                useWeb = true
            }
        }
        return try await web().post(fields)
    }

    private func cityList() async throws -> [String] {
        if !useWeb {
            do {
                return try await urlT.cityOptions()
            } catch let e as DtekError where e.needsWeb {
                guard allowWeb else { throw e }
                useWeb = true
            }
        }
        return try await web().cityOptions()
    }

    // MARK: варіанти написання

    private static func regexReplace(_ s: String, _ pattern: String, _ with: String, ci: Bool = false) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
    }

    private static func base(_ s: String) -> String {
        var t = regexReplace(s.trimmingCharacters(in: .whitespacesAndNewlines), #"\s+"#, " ")
        t = regexReplace(t, #"^(м|с|смт|с-ще|вул|пров|просп|бул|пл|узв|наб)(\.\s*|\s+)"#, "", ci: true)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func title(_ s: String) -> String {
        var out = ""
        var boundary = true
        for ch in s.lowercased() {
            if boundary && ch.isLetter { out += String(ch).uppercased() } else { out.append(ch) }
            boundary = ch.isWhitespace || ch == "-"
        }
        return out
    }

    private static func cap(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Усі варіанти написання (місто, вулиця), які перебираємо, поки сайт не впізнає адресу.
    static func candidates(_ city: String, _ street: String) -> [(String, String)] {
        let cityPrefixes = ["м.", "с.", "смт", "с-ще"]
        let streetPrefixes = ["вул.", "пров.", "просп.", "бул.", "пл.", "узв.", "наб."]
        let c = title(base(city))
        let sb = base(street)
        var names: [String] = []
        for n in [cap(sb), title(sb)] where !names.contains(n) { names.append(n) }

        var out: [(String, String)] = [(
            city.trimmingCharacters(in: .whitespacesAndNewlines),
            street.trimmingCharacters(in: .whitespacesAndNewlines)
        )]
        for cp in cityPrefixes {
            for sp in streetPrefixes {
                for sn in names {
                    out.append(("\(cp) \(c)", "\(sp) \(sn)"))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.0 + "\u{0}" + $0.1).inserted }
    }

    // MARK: перевірка адреси

    func fetch(pairs: [(String, String)]) async throws -> FetchResult {
        let now = Sched.fmt(Date(), "dd.MM.yyyy HH:mm")
        for (c, s) in pairs {
            try Task.checkCancellation()
            let t = try await post([
                ("method", "getHomeNum"),
                ("data[0][name]", "city"), ("data[0][value]", c),
                ("data[1][name]", "street"), ("data[1][value]", s),
                ("data[2][name]", "updateFact"), ("data[2][value]", now)
            ])
            guard let j = Sched.json(t) else { throw DtekError("відповідь сайту не вдалося прочитати") }
            if (j["result"] as? Bool) == true, let d = j["data"], !(d is NSNull) {
                return FetchResult(raw: t, city: c, street: s)
            }
        }
        throw DtekError("адресу не знайдено на сайті ДТЕК: перевірте місто і вулицю")
    }

    static func parse(_ raw: String, house: String) throws -> Parsed {
        guard let root = Sched.json(raw) else { throw DtekError("не вдалося прочитати відповідь сайту") }
        guard let data = root["data"] as? [String: Any] else {
            throw DtekError("у відповіді сайту немає даних про будинки")
        }
        let hh = house.trimmingCharacters(in: .whitespaces)
        var key: String? = nil
        for k in data.keys where k.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(hh) == .orderedSame {
            key = k
        }
        guard let kk = key, let h = data[kk] as? [String: Any] else {
            throw DtekError("будинок «\(house)» не знайдено серед \(data.count) будинків цієї вулиці")
        }
        var groups: [String] = []
        var ids: [String] = []
        if let arr = h["sub_type_reason"] as? [Any] {
            for x in arr {
                let s = Sched.str(x)
                if let r = s.range(of: #"\d+\.\d+"#, options: .regularExpression) {
                    groups.append(String(s[r]))
                    ids.append(s.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        let start = Sched.str(h["start_date"])
        return Parsed(
            groups: groups.isEmpty ? "?" : groups.joined(separator: ", "),
            emergency: !start.trimmingCharacters(in: .whitespaces).isEmpty,
            reason: Sched.str(h["sub_type"]),
            start: start,
            end: Sched.str(h["end_date"]),
            updated: Sched.str(root["updateTimestamp"]),
            groupId: ids.first ?? ""
        )
    }

    // MARK: підказки адрес

    private static func extractStreets(_ d: Any?) -> [String] {
        var out: [String] = []
        if let arr = d as? [Any] {
            for x in arr {
                if let s = x as? String {
                    out.append(s)
                } else if let o = x as? [String: Any] {
                    for k in ["name", "value", "title", "street"] {
                        let v = Sched.str(o[k])
                        if !v.isEmpty { out.append(v); break }
                    }
                }
            }
        } else if let o = d as? [String: Any] {
            for (k, v) in o { out.append((v as? String) ?? k) }
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Список міст зі сторінки + вулиці міста (перший варіант написання, який знайшов сайт).
    func directory(targets: [String]) async throws -> Dir {
        let cities = try await cityList()
        for t in targets {
            try Task.checkCancellation()
            do {
                let txt = try await post([
                    ("method", "getStreets"),
                    ("data[0][name]", "city"), ("data[0][value]", t)
                ])
                if let j = Sched.json(txt), (j["result"] as? Bool) == true {
                    let st = Self.extractStreets(j["data"])
                    if !st.isEmpty {
                        return Dir(cities: cities.sorted(), city: t,
                                   streets: Array(Set(st)).sorted())
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return Dir(cities: cities.sorted(), city: "", streets: [])
    }

    /// Номери будинків вулиці.
    func houses(pairs: [(String, String)]) async throws -> [String] {
        let now = Sched.fmt(Date(), "dd.MM.yyyy HH:mm")
        for (c, s) in pairs {
            try Task.checkCancellation()
            let t = try await post([
                ("method", "getHomeNum"),
                ("data[0][name]", "city"), ("data[0][value]", c),
                ("data[1][name]", "street"), ("data[1][value]", s),
                ("data[2][name]", "updateFact"), ("data[2][value]", now)
            ])
            guard let j = Sched.json(t) else { throw DtekError("відповідь сайту не вдалося прочитати") }
            if (j["result"] as? Bool) == true, let d = j["data"] as? [String: Any] {
                return Array(d.keys)
            }
        }
        return []
    }
}
