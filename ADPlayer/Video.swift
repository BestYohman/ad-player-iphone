import SwiftUI
import AVFoundation

// Shared by the iPhone and the Apple TV apps: the colours, the poster fields and the video.

// MARK: - Low and full vision: the poster layout, like the AD Player web page

/// The colours of the screen: full vision's dark look, or low vision's dark, light or yellow on black.
struct Look {
    let bg, fg, sub, card, accent, btn, btnFg, line: Color
    let low: Bool

    @MainActor static func of(_ m: AppModel) -> Look {
        guard m.low else {
            return Look(bg: Color(red: 0.043, green: 0.051, blue: 0.067), fg: .white, sub: Color(white: 0.72),
                        card: Color(white: 0.11), accent: Color(red: 0.18, green: 0.83, blue: 0.75), btn: .white, btnFg: .black,
                        line: Color(white: 0.25), low: false)
        }
        switch m.opts.screen ?? "dark" {
        case "light":
            return Look(bg: .white, fg: .black, sub: .black, card: Color(white: 0.95), accent: Color(red: 0, green: 0.2, blue: 0.63),
                        btn: Color(red: 0, green: 0.2, blue: 0.63), btnFg: .white, line: .black, low: true)
        case "yellow":
            let y = Color(red: 1, green: 0.84, blue: 0.04)
            return Look(bg: .black, fg: y, sub: y, card: Color(red: 0.1, green: 0.1, blue: 0), accent: y, btn: .white, btnFg: .black,
                        line: y, low: true)
        default:
            return Look(bg: .black, fg: .white, sub: .white, card: Color(white: 0.04), accent: Color(red: 1, green: 0.84, blue: 0.04),
                        btn: Color(red: 1, green: 0.84, blue: 0.04), btnFg: .black, line: .white, low: true)
        }
    }

    var lineWidth: CGFloat { low ? 3 : 1 }

    @MainActor static func typeSize(_ m: AppModel) -> DynamicTypeSize {
        guard m.low else { return .large }
        switch m.opts.size ?? "large" {
        case "normal": return .xLarge
        case "larger": return .accessibility2
        case "largest": return .accessibility4
        default: return .xxxLarge
        }
    }
}

/// A poster or a picture in a list (the web page's fields).
struct Card: Decodable, Identifiable, Hashable {
    let id: String
    let type: String?
    let label: String
    let name: String?
    let poster: String?
    let thumb: String?
    let backdrop: String?
    let hasAD: Bool?
    let pct: Int?
    let resume: String?
    let seriesName: String?
    let length: String?

    enum CodingKeys: String, CodingKey {
        case id, type, label, name, poster, thumb, backdrop, pct, resume, length
        case hasAD = "has_ad"
        case seriesName = "series_name"
    }
}

struct CardsResponse: Decodable { let items: [Card] }

/// An empty text counts as none (the PC sends "" for a picture it doesn't have).
func nz(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }

// MARK: - First sign-in: how do you see the screen?

let SIGHTS: [(String, String, String, [String])] = [
    ("none", "No vision", "I use a screen reader and don't look at the screen.",
     ["Audio-only layout", "Short lists in reading order", "Everything spoken, nothing to look at"]),
    ("low", "Low vision", "I can see the screen, but it needs to be big and clear.",
     ["Large text and buttons", "High contrast, light or dark", "Fewer things on each line"]),
    ("full", "Full vision", "I see the screen fine.", ["Posters and rows", "Like other media apps", "Still works with VoiceOver"]),
]

func sightName(_ v: String) -> String { SIGHTS.first { $0.0 == v }?.1 ?? "No vision" }
func sightSaid(_ v: String) -> String {
    sightName(v) + (v == "none" ? ": the audio-only layout." : v == "low" ? ": big text and high contrast." : ": the poster layout.")
}


// MARK: - The video on this phone

struct VideoPrepare: Decodable {
    let tok: String
    let url: String
    let title: String?
    let runtimeTicks: Double?
    let resumeTicks: Double?
    let hasNext: Bool?
    let aidx: Int?
    enum CodingKeys: String, CodingKey {
        case tok, url, title, aidx
        case runtimeTicks = "runtime_ticks"
        case resumeTicks = "resume_ticks"
        case hasNext = "has_next"
    }
}

struct TrackList: Decodable {
    struct Track: Decodable, Hashable { let index: Int?; let label: String; let ad: Bool? }
    let audio: [Track]
}

/// The video (Emby's stream, passed through the PC, with the sound track she picked - audio description first).
@MainActor
final class VideoModel: ObservableObject {
    @Published var shown = false
    @Published private(set) var active = false
    @Published private(set) var paused = false
    @Published private(set) var title = ""
    @Published var stats = false
    let player = AVPlayer()
    weak var model: AppModel?
    private(set) var tok = ""
    private(set) var item: Item?
    private(set) var aidx: Int?
    private(set) var runtime: Double = 0
    private var hasNext = false
    private var saveTask: Task<Void, Never>?
    private var endObs: NSObjectProtocol?

    private var statusObs: NSKeyValueObservation?
    private var failObs: NSObjectProtocol?

    init() {
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible     // the description goes on with the screen locked
        statusObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let paused = p.timeControlStatus == .paused
            Task { @MainActor in if self?.active == true { self?.paused = paused } }
        }
    }

    func start(_ it: Item, resume: Bool, aidx a: Int? = nil, at: Double? = nil, show: Bool = true) {
        guard let api = model?.api else { return }
        model?.phone.stop(saving: true, quiet: true, notify: false)
        model?.book.stop(saving: true, quiet: true, notify: false)
        if model?.together.active == true { model?.together.leave(quiet: true) }
        model?.say("Starting \(it.label).")
        Task {
            do {
                var f = ["item": it.id]
                if let a = a { f["aidx"] = String(a) } else { f["aidx"] = "-3" }        // audio description first, when there is one
                let r = try await api.post("api/play/video/prepare", f, as: VideoPrepare.self)
                guard let url = api.media(r.url) else { return }
                if !self.tok.isEmpty && self.tok != r.tok { self.stopStream(self.tok) }
                self.tok = r.tok; self.item = it; self.aidx = r.aidx
                self.title = r.title ?? it.label
                self.runtime = (r.runtimeTicks ?? 0) / 10_000_000
                self.hasNext = r.hasNext ?? false
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
                try? AVAudioSession.sharedInstance().setActive(true)
                let pi = AVPlayerItem(url: url)
                self.player.replaceCurrentItem(with: pi)
                let pos = at ?? (resume ? (r.resumeTicks ?? 0) / 10_000_000 : 0)
                if pos > 5 { await self.player.seek(to: CMTime(seconds: max(0, pos - 3), preferredTimescale: 600)) }
                self.player.play()
                self.active = true; self.paused = false
                if show { self.shown = true }
                self.watchEnd(pi)
                self.saveLoop()
            } catch {
                self.model?.say(error.localizedDescription)
            }
        }
    }

    func playPause() {
        if player.timeControlStatus == .paused { player.play(); paused = false; model?.say("Playing.") }
        else { player.pause(); paused = true; save(); model?.say("Paused.") }
    }

    func skip(_ s: Double) {
        let t = max(0, player.currentTime().seconds + s)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    func switchAudio(_ index: Int) {
        guard let it = item else { return }
        start(it, resume: false, aidx: index, at: player.currentTime().seconds + 3)
    }

    func stop(saving: Bool = true) {
        if saving { save() }
        saveTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if !tok.isEmpty { stopStream(tok) }
        tok = ""; active = false; shown = false; stats = false; item = nil
    }

    private func stopStream(_ t: String) {
        guard let api = model?.api else { return }
        Task { _ = try? await api.post("api/play/video/stop", ["tok": t], as: MessageResponse.self) }
    }

    func save(finished: Bool = false) {
        guard let api = model?.api, let it = item else { return }
        let pos = player.currentTime().seconds
        guard pos.isFinite else { return }
        Task {
            _ = try? await api.post("api/play/listen/save", ["item": it.id, "pos": String(format: "%.1f", pos), "finished": finished ? "1" : "0",
                                                             "at": String(format: "%.0f", Date().timeIntervalSince1970)], as: MessageResponse.self)
        }
    }

    private func saveLoop() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self = self, self.active else { return }
                if self.player.timeControlStatus == .playing { self.save() }
                self.paused = self.player.timeControlStatus == .paused
            }
        }
    }

    private func watchEnd(_ pi: AVPlayerItem) {
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: pi, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        if let o = failObs { NotificationCenter.default.removeObserver(o) }
        failObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: pi, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model?.say("The video stopped working. Press Stop, then start it again.") }
        }
    }

    private func ended() {
        save(finished: true)
        guard let api = model?.api, let it = item else { return }
        let done = title
        Task {
            if self.hasNext, let r = try? await api.get("api/play/listen/next", ["item": it.id, "kind": "video"], as: NextResponse.self), let n = r.item {
                self.start(n, resume: true, show: self.shown)
            } else {
                self.stop(saving: false)
                self.model?.say("Finished \(done).")
            }
        }
    }
}

struct VideoStats: Decodable {
    struct Emby: Decodable { let video: String?; let audio: String?; let size: String?; let mbps: Double?; let hw: String?; let reasons: String? }
    struct Source: Decodable { let container: String?; let mbps: Double?; let video: String?; let audio: String?; let audioName: String?
        enum CodingKeys: String, CodingKey { case container, mbps, video, audio; case audioName = "audio_name" } }
    let emby: Emby?
    let source: Source?
    let outKbps: Int?
    let bytes: Int?
    let maxMbps: Double?
    enum CodingKeys: String, CodingKey {
        case emby, source, bytes
        case outKbps = "out_kbps"
        case maxMbps = "max_mbps"
    }
}

/// Like YouTube's "Stats for nerds": this phone's side and the PC's side.
struct StatsPanel: View {
    #if os(tvOS)
    static let tv = true
    #else
    static let tv = false
    #endif
    @EnvironmentObject var model: AppModel
    @ObservedObject var video: VideoModel
    @State private var srv: VideoStats?
    @State private var rtt = 0
    @State private var lines: [String] = []

    var body: some View {
        Text(lines.joined(separator: "\n"))
            .font(.system(size: StatsPanel.tv ? (model.low ? 30 : 22) : (model.low ? 15 : 11), design: .monospaced))
            .foregroundStyle(.white)
            .padding(StatsPanel.tv ? 24 : 10)
            .frame(maxWidth: StatsPanel.tv ? 1200 : 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(model.low ? 1 : 0.8)))
            .task {
                var n = 0
                while !Task.isCancelled {
                    if n % 3 == 0, let api = model.api, !video.tok.isEmpty {
                        let t0 = Date()
                        if let s = try? await api.get("api/play/video/stats", ["tok": video.tok], as: VideoStats.self) {
                            srv = s; rtt = Int(Date().timeIntervalSince(t0) * 1000)
                        }
                    }
                    lines = draw(); n += 1
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
    }

    private func draw() -> [String] {
        let p = video.player
        var L = ["Video          \(video.title)"]
        if let it = p.currentItem {
            let sz = it.presentationSize
            L.append("Resolution     \(Int(sz.width))x\(Int(sz.height))")
            if let e = it.accessLog()?.events.last {
                L.append("Frames         \(e.numberOfDroppedVideoFrames) dropped, \(e.numberOfStalls) stalls")
                if e.indicatedBitrate > 0 { L.append(String(format: "Stream         %.1f Mbps", e.indicatedBitrate / 1e6)) }
                if e.observedBitrate > 0 { L.append("Connection     \(Int(e.observedBitrate / 1000)) Kbps") }
                L.append("Network        \(e.numberOfBytesTransferred / 1024) KB in \(Int(e.transferDuration)) s")
            }
            let now = p.currentTime().seconds
            if let r = it.loadedTimeRanges.map({ $0.timeRangeValue }).first(where: { $0.start.seconds <= now && $0.end.seconds >= now }) {
                L.append(String(format: "Buffer health  %.1f s", r.end.seconds - now))
            }
            L.append("Playback       \(Speak.position(now)) of \(Speak.duration(video.runtime))   speed \(p.rate)")
        }
        if let s = srv {
            if let e = s.emby {
                L.append("Emby           video \(e.video ?? "?"), audio \(e.audio ?? "?")" + (e.size.map { ", \($0)" } ?? "") +
                         (e.mbps.map { $0 > 0 ? ", \($0) Mbps" : "" } ?? "") + ((e.hw ?? "").isEmpty ? "" : ", \(e.hw!)"))
                if let r = e.reasons, !r.isEmpty { L.append("  why remade   \(r)") }
            }
            if let so = s.source {
                L.append("Source         \(so.container ?? ""), \(so.mbps ?? 0) Mbps")
                if let v = so.video { L.append("  video        \(v)") }
                if let a = so.audio { L.append("  sound        \(a)") }
                if let n = so.audioName, !n.isEmpty { L.append("  track        \(n)") }
            }
            L.append("From the PC    \(s.outKbps.map { "\($0) Kbps" } ?? "-"), \((s.bytes ?? 0) / 1_048_576) MB sent, limit \(s.maxMbps ?? 0) Mbps")
            L.append("PC answers in  \(rtt) ms")
        } else { L.append("Asking the PC…") }
        return L
    }
}
