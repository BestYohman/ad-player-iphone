import Foundation

// Talks to the AD Player that runs inside describealign_ultimate.py on the PC (port 5021).
// It uses the same addresses the /play web page uses, so nothing new is needed on the PC.

enum APIError: LocalizedError {
    case server(String)
    case badAddress
    case network

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .badAddress: return "The address of the PC doesn't look right. Check it in Settings."
        case .network: return "Couldn't reach the PC. Is it turned on, and is this phone on the home Wi-Fi?"
        }
    }
}

struct API {
    let base: URL

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
        try await send(URLRequest(url: url(path, query)), as: type)
    }

    func post<T: Decodable>(_ path: String, _ form: [String: String], as type: T.Type) async throws -> T {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
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

    enum CodingKeys: String, CodingKey {
        case playing, paused, text, ad, title
        case hasAD = "has_ad"
        case hasNext = "has_next"
        case posTicks = "pos_ticks"
        case runTicks = "run_ticks"
    }
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

    enum CodingKeys: String, CodingKey {
        case id, state, progress, error, title, playable, url
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
