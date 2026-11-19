import Foundation
import CryptoKit
import Security

// Talks to the AD Player that runs inside describealign_ultimate.py on the PC (port 5021).
// It uses the same addresses the /play web page uses, so nothing new is needed on the PC.

enum APIError: LocalizedError {
    case server(String)
    case badAddress
    case network
    case signIn(String)
    case networkWhy(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .signIn(let message): return message
        case .badAddress: return "The address of the PC doesn't look right. Check it in Settings."
        case .network: return "Couldn't reach the PC. Is it turned on, and is this phone on the home Wi-Fi?"
        case .networkWhy(let why): return "Couldn't reach the PC: \(why)"
        }
    }
}

struct API {
    let base: URL

    /// This phone's sign-in (from the PC, after signing in with the Emby user name and password). Sent with every request.
    static var token: String = Keychain.get("token") ?? ""
    /// Called when the PC says to sign in (again).
    static var signInNeeded: (@MainActor () -> Void)?

    /// No cookies at all: the PC's sign-in cookie (for the web page) is never kept or sent by the app.
    static func noCookies(_ c: URLSessionConfiguration) {
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
    }

    /// For trying home addresses: no sign-in, no cookies, and no following a redirect somewhere else.
    private static let quick: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2.5
        c.timeoutIntervalForResource = 3
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        noCookies(c)
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }()

    /// Asks quickly whether the PC is at this address, without the sign-in (used to find it on the home Wi-Fi).
    /// Nil if it didn't answer.
    func quickMe(_ query: [String: String?] = [:]) async -> Me? {
        var r = URLRequest(url: url("api/play/me", query))
        r.httpShouldHandleCookies = false
        guard let result = try? await API.quick.data(for: r),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Me.self, from: result.0)
    }

    /// An address on the home network (or this phone): 10.x, 172.16-31.x, 192.168.x, 127.x, localhost, a .local
    /// name, or a name without a dot. Only these get plain http when typed without http:// or https://.
    static func lan(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.isEmpty || h == "localhost" || h.hasSuffix(".local") { return true }
        let n = h.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if n.count == 4, n.allSatisfy({ $0 != nil && (0...255).contains($0!) }) {
            let x = n[0]!, y = n[1]!
            return x == 10 || x == 127 || (x == 172 && (16...31).contains(y)) || (x == 192 && y == 168)
        }
        return !h.contains(".") && !h.contains(":")
    }

    /// The host of typed text, before anything is added to it.
    private static func typedHost(_ s: String) -> String {
        var h = s
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        h = String(h.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        h = String(h.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if h.hasPrefix("["), let end = h.firstIndex(of: "]") { return String(h[h.index(after: h.startIndex)..<end]) }
        if let colon = h.lastIndex(of: ":") { h = String(h[..<colon]) }
        return h
    }

    /// "192.168.1.20" or "192.168.1.20:5021" or "http://mypc:5021/play" -> http://192.168.1.20:5021;
    /// "player.example.com" -> https://player.example.com (plain http only for an address at home)
    static func normalise(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { s = (lan(typedHost(s)) ? "http://" : "https://") + s }
        guard var parts = URLComponents(string: s), let host = parts.host, !host.isEmpty else { return nil }
        // the PC at home (an IP address or a name without dots) is on port 5021; a web address is used as typed
        // (its own port, or the normal one - https or a forwarded port 80)
        let local = host.allSatisfy { $0.isNumber || $0 == "." } || !host.contains(".") || host.hasSuffix(".local") || host.hasSuffix(".lan")
        if parts.port == nil && local && parts.scheme == "http" { parts.port = 5021 }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// The addresses to try for what was typed: as it is, then (an address at home with no port) on port 5021 too.
    static func candidates(_ text: String) -> [URL] {
        guard let u = normalise(text) else { return [] }
        var out = [u]
        if var parts = URLComponents(url: u, resolvingAgainstBaseURL: false), parts.port == nil, parts.scheme == "http",
           lan(parts.host ?? "") {
            parts.port = 5021
            if let alt = parts.url { out.append(alt) }
        }
        return out
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        noCookies(c)
        return URLSession(configuration: c, delegate: SameHostRedirect(), delegateQueue: nil)
    }()

    func url(_ path: String, _ query: [String: String?] = [:]) -> URL {
        let full = base.appendingPathComponent(path)
        guard var parts = URLComponents(url: full, resolvingAgainstBaseURL: false) else { return full }
        var items: [URLQueryItem] = []
        for (key, value) in query {
            if let value = value { items.append(URLQueryItem(name: key, value: value)) }
        }
        if !items.isEmpty { parts.queryItems = items }
        return parts.url ?? full
    }

    /// A link the PC gave back, like /api/play/listen/hls/<key>/index.m3u8
    func media(_ path: String) -> URL? {
        URL(string: path, relativeTo: base)?.absoluteURL
    }

    /// What went wrong, in words someone can act on.
    static func explain(_ e: URLError) -> APIError {
        if e.networkUnavailableReason == .cellular {
            return .networkWhy("mobile data is turned off for AD Player. In the iPhone's Settings, open Apps, then AD Player, and turn on Mobile Data (on older iPhones: Settings, Mobile Data, AD Player).")
        }
        switch e.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return .networkWhy("this iPhone has no internet connection right now - or mobile data is turned off for AD Player (Settings, Apps, AD Player, Mobile Data).")
        case .cannotFindHost, .dnsLookupFailed:
            return .networkWhy("the iPhone couldn't find that address. Check its spelling in Settings.")
        case .timedOut:
            return .networkWhy("it took too long to answer. On the home Wi-Fi, use the PC's own address (like 192.168.2.10).")
        case .appTransportSecurityRequiresSecureConnection:
            return .networkWhy("this address needs https. Type it with https:// in Settings.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            return .networkWhy("the secure (https) connection failed.")
        default:
            return .networkWhy(e.localizedDescription)
        }
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:], as type: T.Type) async throws -> T {
        var request = URLRequest(url: url(path, query))
        request.httpShouldHandleCookies = false
        if !API.token.isEmpty { request.setValue(API.token, forHTTPHeaderField: "X-ADP-Token") }
        return try await send(request, as: type)
    }

    /// token: another sign-in to send instead of this phone's own (a sign-out kept for later).
    func post<T: Decodable>(_ path: String, _ form: [String: String], token: String? = nil, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        let t = token ?? API.token
        if !t.isEmpty { request.setValue(t, forHTTPHeaderField: "X-ADP-Token") }
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = (body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        request.httpBody = encoded.data(using: .utf8)
        return try await send(request, as: type)
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let result: (Data, URLResponse)
        do {
            result = try await API.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError {
            throw API.explain(e)
        } catch {
            throw APIError.network
        }
        let data = result.0
        if let http = result.1 as? HTTPURLResponse, http.statusCode == 401 {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (object?["error"] as? String) ?? "Please sign in."
            if let hook = API.signInNeeded { Task { @MainActor in hook() } }
            throw APIError.signIn(message)
        }
        if let http = result.1 as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.server("The PC answered with an error (\(http.statusCode)). Is the AD Player port turned on in the app's settings?")
        }
        // the PC reports problems as {"error": "..."}
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty {
            throw APIError.server(message)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.server("The PC sent something this app didn't expect. Make sure the app on the PC is up to date.")
        }
    }
}

// MARK: - What the PC sends back

/// Who is signed in on this phone, and about the PC.
struct Me: Decodable {
    let signedIn: Bool?
    let name: String?
    let role: String?
    let away: Bool?
    let loginNeeded: Bool?
    let serverID: String?
    let homeURLs: [String]?
    /// The answer to the home-address check (asked with ?nonce=...&kid=...).
    var lanProof: String? = nil
    /// The key for that check (asked with ?lan_key=1 and the sign-in, over the address typed in).
    var lanProofID: String? = nil
    var lanProofKey: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, role, away
        case signedIn = "signed_in"
        case loginNeeded = "login_needed"
        case serverID = "server_id"
        case homeURLs = "home_urls"
        case lanProof = "lan_proof"
        case lanProofID = "lan_proof_id"
        case lanProofKey = "lan_proof_key"
    }
}

struct LoginResponse: Decodable {
    let message: String
    let token: String?
    var lanProofID: String? = nil
    var lanProofKey: String? = nil

    enum CodingKeys: String, CodingKey {
        case message, token
        case lanProofID = "lan_proof_id"
        case lanProofKey = "lan_proof_key"
    }
}

/// Never follows a redirect (the home-address check: on someone else's Wi-Fi that address can be anyone).
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Follows a redirect, but the sign-in only goes along to the same address (and never from https to http).
final class SameHostRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var r = request
        let from = task.originalRequest?.url
        let same = from?.host?.lowercased() == request.url?.host?.lowercased() && from?.port == request.url?.port
        let downgrade = from?.scheme == "https" && request.url?.scheme != "https"
        if !same || downgrade { r.setValue(nil, forHTTPHeaderField: "X-ADP-Token") }
        r.httpShouldHandleCookies = false
        completionHandler(r)
    }
}

/// The home-address check (as the Android app does it): at sign-in the PC gives this phone a key, over the address
/// typed in. On the home Wi-Fi, a home address is only used (and sent the sign-in) once it answers a random
/// question (nonce) with that key: HMAC-SHA256, in hex. Only this PC and this phone know the key.
enum LanProof {
    private static var cachedID: String?
    private static var cachedKey: String?

    static var id: String {
        if cachedID == nil { cachedID = Keychain.get("lan_id") ?? "" }
        return cachedID ?? ""
    }
    static var key: String {
        if cachedKey == nil { cachedKey = Keychain.get("lan_key") ?? "" }
        return cachedKey ?? ""
    }
    static var has: Bool { !id.isEmpty && !key.isEmpty }

    static func remember(id newID: String?, key newKey: String?) {
        guard let i = newID, let k = newKey, !i.isEmpty, !k.isEmpty else { return }
        Keychain.set("lan_id", i)
        Keychain.set("lan_key", k)
        cachedID = i
        cachedKey = k
    }

    static func forget() {
        Keychain.set("lan_id", nil)
        Keychain.set("lan_key", nil)
        cachedID = ""
        cachedKey = ""
    }

    /// 16 random bytes, in hex.
    static func nonce() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, b.count, &b) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            for i in b.indices { b[i] = UInt8.random(in: 0...255, using: &g) }
        }
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func expected(_ nonce: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the answer is right (compared in constant time).
    static func matches(_ proof: String?, nonce: String) -> Bool {
        guard has, let p = proof?.lowercased() else { return false }
        let a = Array(p.utf8), b = Array(expected(nonce).utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// Playing together: what the PC says about the shared clock.
struct Room: Decodable {
    let id: String?
    let kind: String?
    let item: String?
    let title: String?
    let iseq: Int?
    let run: Bool?
    let want: Bool?
    let waiting: Bool?
    let hold: [String]?
    let pos: Double?
    let rate: Double?
    let runtime: Double?
    let hasNext: Bool?
    let by: String?
    let role: String?
    let msg: String?
    let msgBy: String?
    let msgSeq: Int?
    let others: [String]?
    let notReady: [String]?
    let gone: Bool?
    let left: Bool?
    let jseq: Int?

    enum CodingKeys: String, CodingKey {
        case id, kind, item, title, iseq, run, want, waiting, hold, pos, rate, runtime, by, role, msg, others, gone, left, jseq
        case hasNext = "has_next"
        case msgBy = "msg_by"
        case msgSeq = "msg_seq"
        case notReady = "not_ready"
    }
}

struct Invite: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let by: String
    let kind: String
    let names: [String]?
}

struct InvitesResponse: Decodable {
    let rooms: [Invite]
}

struct Device: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let user: String?
    let playing: String?
}

struct DevicesResponse: Decodable {
    let devices: [Device]
    let other: [String]?
}

struct Item: Decodable, Identifiable, Hashable {
    let id: String
    let type: String?
    let label: String
    let length: String?
    let played: Bool?
    let resume: String?
    let resumeTicks: Double?
    let hasAD: Bool?
    var favorite: Bool? = nil
    var requested: Bool? = nil
    var count: Int? = nil
    var text: String? = nil
    var date: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, type, label, length, played, resume, favorite, requested, count, text, date
        case resumeTicks = "resume_ticks"
        case hasAD = "has_ad"
    }

    /// What VoiceOver reads for the row, e.g. "Friends, season 4 episode 2: The One with the Cat, 22 minutes, resumes at 5 minutes"
    var spoken: String {
        if type == "Series" {
            return [label, (count ?? 0) > 0 ? "\(count!) seasons" : "", hasAD == false ? "without description" : ""]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }
        if type == "Season" {
            return [label, (count ?? 0) > 0 ? "\(count!) episodes" : "", played == true ? "watched" : ""]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }
        var parts = [label]
        if let length = length, !length.isEmpty { parts.append(length) }
        if let resume = resume, !resume.isEmpty { parts.append("resumes at \(resume)") }
        if played == true { parts.append("watched") }
        if hasAD == false { parts.append("without description") }
        return parts.joined(separator: ", ")
    }

    var canResume: Bool { (resumeTicks ?? 0) > 0 && !(resume ?? "").isEmpty }
}

struct ItemsResponse: Decodable {
    let items: [Item]
}

struct MessageResponse: Decodable {
    let message: String
}

struct NextResponse: Decodable {
    let item: Item?
}

struct TVStatus: Decodable {
    let playing: Bool
    let paused: Bool?
    let text: String
    let ad: Bool?
    let hasAD: Bool?
    let hasNext: Bool?
    let title: String?
    let posTicks: Double?
    let runTicks: Double?
    // when an audiobook is playing on the TV
    let book: Bool?
    let bookID: String?
    let hasPrev: Bool?
    let sleepVal: String?

    enum CodingKeys: String, CodingKey {
        case playing, paused, text, ad, title, book
        case hasAD = "has_ad"
        case hasNext = "has_next"
        case posTicks = "pos_ticks"
        case runTicks = "run_ticks"
        case bookID = "book_id"
        case hasPrev = "has_prev"
        case sleepVal = "sleep_val"
    }
}

// MARK: - Audiobooks (from Audiobookshelf, through the PC)

/// One row of an audiobook list: a book, a series, an author or a chapter.
struct BookItem: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let label: String
    let author: String?
    let narrator: String?
    let series: String?
    let length: String?
    let chapters: Int?
    let resume: String?
    let pct: Int?
    let finished: Bool?
    let count: Int?
    let book: String?
    let bookTitle: String?
    let start: Double?
    let at: String?

    enum CodingKeys: String, CodingKey {
        case id, type, label, author, narrator, series, length, chapters, resume, pct, finished, count, book, start, at
        case bookTitle = "book_title"
    }

    var canResume: Bool { !(resume ?? "").isEmpty }

    /// What VoiceOver reads, worded like the web page:
    /// "The Hobbit, by J.R.R. Tolkien, read by Andy Serkis, 10 hours 25 minutes, 35 percent done, resumes at 3 hours 2 minutes"
    var spoken: String {
        switch type {
        case "BookSeries", "BookAuthor":
            guard let n = count, n > 0 else { return label }
            return "\(label), \(Speak.count(n, "book"))"
        case "Chapter":
            let number = (Int(id.split(separator: "|").last ?? "") ?? 0) + 1
            let lower = label.lowercased()
            let name = (lower.hasPrefix("chapter") || lower.hasPrefix("part")) ? label : "Chapter \(number): \(label)"
            return name + (at.map { ", starts at \($0)" } ?? "")
        default:
            var parts = [label]
            if let a = author, !a.isEmpty { parts.append("by \(a)") }
            if let n = narrator, !n.isEmpty { parts.append("read by \(n)") }
            if let s = series, !s.isEmpty { parts.append(s) }
            if let l = length, !l.isEmpty { parts.append(l) }
            if canResume {
                parts.append(((pct ?? 0) > 0 ? "\(pct ?? 0) percent done, " : "") + "resumes at \(resume ?? "")")
            } else if finished == true {
                parts.append("finished")
            }
            return parts.joined(separator: ", ")
        }
    }
}

struct BookItemsResponse: Decodable {
    let items: [BookItem]
}

struct BookChapter: Codable, Hashable {
    let start: Double
    let end: Double
    let title: String
}

/// One file of a book. url plays the file as it is; tx is the PC's MP3 version (add ?t=seconds).
struct BookTrack: Codable, Hashable {
    let start: Double
    let duration: Double
    let ino: String
    let mime: String?
    let codec: String?
    let url: String
    let tx: String
}

struct BookDetail: Codable {
    let id: String
    let title: String
    let author: String?
    let narrator: String?
    let duration: Double
    let chapters: [BookChapter]
    let tracks: [BookTrack]
    let position: Double
    let finished: Bool
    let cover: String?
    let segs: [BookSeg]?
}

/// A piece of a book as the phone fetches it: a part as it is, or 10 minutes of a long file.
struct BookSeg: Codable, Hashable {
    let start: Double
    let duration: Double
    let url: String
}

struct ListenJob: Decodable {
    let id: String
    let state: String
    let progress: Double?
    let error: String?
    let title: String?
    let runtimeTicks: Double?
    let resumeTicks: Double?
    let hasNext: Bool?
    let encodedSeconds: Double?
    let playable: Bool?
    let url: String?
    let fullURL: String?
    let hasAD: Bool?

    enum CodingKeys: String, CodingKey {
        case id, state, progress, error, title, playable, url
        case fullURL = "full_url"
        case hasAD = "has_ad"
        case runtimeTicks = "runtime_ticks"
        case resumeTicks = "resume_ticks"
        case hasNext = "has_next"
        case encodedSeconds = "encoded_s"
    }
}

// MARK: - Spoken times, worded the same way as the web page

enum Speak {
    static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// "12 minutes", "1 hour 5 minutes", "40 seconds"
    static func position(_ seconds: Double) -> String {
        let t = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return count(h, "hour") + " " + count(m, "minute") }
        if m > 0 { return count(m, "minute") }
        return count(s, "second")
    }

    /// rounded to the minute: "45 minutes", "2 hours 3 minutes"
    static func duration(_ seconds: Double) -> String {
        let m = Int((max(0, seconds.isFinite ? seconds : 0) / 60).rounded())
        if m < 60 { return count(m, "minute") }
        let h = m / 60, r = m % 60
        return count(h, "hour") + (r > 0 ? " " + count(r, "minute") : "")
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// "Playing Friends, season 4 episode 2. 12 minutes in, 10 minutes left. Ends at 9:42 PM."
    static func whereAmI(title: String, position pos: Double, total: Double, paused: Bool, on place: String) -> String {
        var s = "\(paused ? "Paused" : "Playing") \(title)\(place). \(position(pos)) in"
        if total > 0 {
            let left = max(0, total - pos)
            s += ", \(duration(left)) left"
            if !paused { s += ". Ends at \(clock(Date().addingTimeInterval(left)))" }
        }
        return s + "."
    }
}

/// One of her bookmarks in a book (Audiobookshelf's own, so they show in its apps too).
struct BookmarkEntry: Decodable, Identifiable, Hashable {
    let time: Double
    let title: String
    let at: String
    let chapter: String?
    var id: Double { time }

    /// What VoiceOver reads: the name, where it is, and the chapter when the name doesn't already say it.
    var spoken: String {
        var s = "\(title), at \(at)"
        if let c = chapter, !c.isEmpty, !title.contains(c) { s += ", in \(c)" }
        return s
    }
}

struct BookmarksResponse: Decodable {
    let bookmarks: [BookmarkEntry]
    let message: String?
}

// MARK: - Sort and filter (the shows and movies lists, as on the web page)

/// How a list is sorted and filtered; kept on the phone for each list.
struct ListView: Codable, Equatable {
    var sort = "title"
    var desc = false
    var state = ""
    var fav = false
    var genre = ""
    var rating = ""
    var year = ""

    /// key, name, newest / highest first when chosen
    static let sorts: [(String, String, Bool)] = [
        ("title", "Title", false), ("added", "Date added", true), ("played", "Date played", true),
        ("released", "Release date", true), ("year", "Year", true), ("runtime", "Runtime", false),
        ("critic", "Critic rating", true), ("rating", "Community rating", true), ("parental", "Parental rating", false),
        ("plays", "Plays", true), ("random", "Random", false)]
    static let states: [(String, String)] = [("", "Any"), ("unplayed", "Not watched"), ("played", "Watched"), ("resumable", "In progress")]

    static func ways(_ sort: String) -> (String, String) {
        switch sort {
        case "title": return ("A to Z", "Z to A")
        case "added", "played", "released", "year": return ("Oldest first", "Newest first")
        case "runtime": return ("Shortest first", "Longest first")
        default: return ("Lowest first", "Highest first")
        }
    }

    var filtersOn: Int { [!state.isEmpty, fav, !genre.isEmpty, !rating.isEmpty, !year.isEmpty].filter { $0 }.count }

    var query: [String: String?] {
        var q: [String: String?] = ["sort": sort, "desc": desc ? "1" : "0"]
        if !state.isEmpty { q["state"] = state }
        if fav { q["fav"] = "1" }
        if !genre.isEmpty { q["genre"] = genre }
        if !rating.isEmpty { q["rating"] = rating }
        if !year.isEmpty { q["year"] = year }
        return q
    }

    var summary: String {
        let name = ListView.sorts.first { $0.0 == sort }?.1 ?? "Title"
        let w = ListView.ways(sort)
        var way = desc ? w.1 : w.0
        if sort != "title" { way = way.lowercased() }
        let n = filtersOn
        return "Sort and filter: \(name)" + (sort == "random" ? "" : ", \(way)") + (n > 0 ? ", \(n) filter\(n == 1 ? "" : "s") on" : "")
    }

    static func load(_ kind: String) -> ListView {
        guard let d = UserDefaults.standard.data(forKey: "listview_\(kind)"),
              let v = try? JSONDecoder().decode(ListView.self, from: d) else { return ListView() }
        return v
    }

    func save(_ kind: String) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "listview_\(kind)") }
    }

    /// The lists that can be sorted and filtered.
    static func applies(_ kind: String) -> Bool {
        ["shows", "movies", "noad_shows", "noad_movies", "favorites_shows", "favorites_movies"].contains(kind)
    }
}

struct FilterChoices: Decodable {
    var genres: [String] = []
    var ratings: [String] = []
    var years: [String] = []

    enum CodingKeys: String, CodingKey { case genres, ratings, years }

    init() {}
    static var empty: FilterChoices { FilterChoices() }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = (try? c.decode([String].self, forKey: .genres)) ?? []
        ratings = (try? c.decode([String].self, forKey: .ratings)) ?? []
        if let ys = try? c.decode([Int].self, forKey: .years) { years = ys.map(String.init) }
        else { years = (try? c.decode([String].self, forKey: .years)) ?? [] }
    }
}
