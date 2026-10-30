import Foundation

// Talks to the AD Player that runs inside describealign_ultimate.py on the PC (port 5021).
// It uses the same addresses the /play web page uses, so nothing new is needed on the PC.

enum APIError: LocalizedError {
    case server(String)
    case badAddress
    case network
    case signIn(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .signIn(let message): return message
        case .badAddress: return "The address of the PC doesn't look right. Check it in Settings."
        case .network: return "Couldn't reach the PC. Is it turned on, and is this phone on the home Wi-Fi?"
        }
    }
}

struct API {
    let base: URL

    /// This phone's sign-in (from the PC, after signing in with the Emby user name and password). Sent with every request.
    static var token: String = Keychain.get("token") ?? ""
    /// Called when the PC says to sign in (again).
    static var signInNeeded: (@MainActor () -> Void)?

    private static let quick: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 2.5
        c.timeoutIntervalForResource = 3
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Asks quickly whether the PC is at this address (used to find it on the home Wi-Fi). Nil if it didn't answer.
    func quickMe() async -> Me? {
        guard let result = try? await API.quick.data(from: url("api/play/me")),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Me.self, from: result.0)
    }

    /// "192.168.1.20" or "192.168.1.20:5021" or "http://mypc:5021/play" -> http://192.168.1.20:5021
    static func normalise(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { s = "http://" + s }
        guard var parts = URLComponents(string: s), let host = parts.host, !host.isEmpty else { return nil }
        if parts.port == nil { parts.port = 5021 }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
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

    func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:], as type: T.Type) async throws -> T {
        var request = URLRequest(url: url(path, query))
        if !API.token.isEmpty { request.setValue(API.token, forHTTPHeaderField: "X-ADP-Token") }
        return try await send(request, as: type)
    }

    func post<T: Decodable>(_ path: String, _ form: [String: String], as type: T.Type) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        if !API.token.isEmpty { request.setValue(API.token, forHTTPHeaderField: "X-ADP-Token") }
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

    enum CodingKeys: String, CodingKey {
        case name, role, away
        case signedIn = "signed_in"
        case loginNeeded = "login_needed"
        case serverID = "server_id"
        case homeURLs = "home_urls"
    }
}

struct LoginResponse: Decodable {
    let message: String
    let token: String?
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

    enum CodingKeys: String, CodingKey {
        case id, type, label, length, played, resume
        case resumeTicks = "resume_ticks"
        case hasAD = "has_ad"
    }

    /// What VoiceOver reads for the row, e.g. "Friends, season 4 episode 2: The One with the Cat, 22 minutes, resumes at 5 minutes"
    var spoken: String {
        var parts = [label]
        if let length = length, !length.isEmpty { parts.append(length) }
        if let resume = resume, !resume.isEmpty { parts.append("resumes at \(resume)") }
        if played == true { parts.append("watched") }
        if hasAD == false { parts.append("no audio description") }
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

struct BookChapter: Decodable, Hashable {
    let start: Double
    let end: Double
    let title: String
}

/// One file of a book. url plays the file as it is; tx is the PC's MP3 version (add ?t=seconds).
struct BookTrack: Decodable, Hashable {
    let start: Double
    let duration: Double
    let ino: String
    let mime: String?
    let codec: String?
    let url: String
    let tx: String
}

struct BookDetail: Decodable {
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
struct BookSeg: Decodable, Hashable {
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
