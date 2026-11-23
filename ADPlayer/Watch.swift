import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

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

private let SIGHTS: [(String, String, String, [String])] = [
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

struct SightChoices: View {
    @EnvironmentObject var model: AppModel
    let current: String
    var body: some View {
        let look = Look.of(model)
        VStack(spacing: 12) {
            ForEach(SIGHTS, id: \.0) { s in
                Button {
                    model.sightSave(["sight": s.0], said: sightSaid(s.0))
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: current == s.0 ? "largecircle.fill.circle" : "circle").font(.title2).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.1).font(.title3.bold())
                            Text(s.2)
                            ForEach(s.3, id: \.self) { b in Text("· " + b).font(.subheadline).foregroundStyle(look.sub) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(look.fg)
                    .background(RoundedRectangle(cornerRadius: 18).fill(look.card))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(current == s.0 ? look.accent : look.line, lineWidth: current == s.0 ? 3 : look.lineWidth))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(current == s.0 ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

struct SightChooser: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How do you see the screen?").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Press the one that fits you. Everything works with VoiceOver either way. You can change this any time under You.")
                    .foregroundStyle(.secondary)
                SightChoices(current: "")
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

// MARK: - The tabs

struct WatchRoot: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var video: VideoModel
    @State private var tab = "home"

    var body: some View {
        let look = Look.of(model)
        TabView(selection: $tab) {
            NavigationStack { WatchHome() }
                .tabItem { Label("Home", systemImage: "house") }.tag("home")
            NavigationStack { PosterGrid(kind: "shows", title: "TV shows") }
                .tabItem { Label("Shows", systemImage: "tv") }.tag("shows")
            NavigationStack { PosterGrid(kind: "movies", title: "Movies") }
                .tabItem { Label("Movies", systemImage: "film") }.tag("movies")
            NavigationStack { BooksTab() }
                .tabItem { Label("Books", systemImage: "headphones") }.tag("books")
            NavigationStack { YouPage() }
                .tabItem { Label("You", systemImage: "person.crop.circle") }.tag("you")
        }
        .tint(look.accent)
        .modifier(LowSize(size: model.low ? Look.typeSize(model) : nil))
        .preferredColorScheme(look.bg == .white ? .light : .dark)
        .overlay(alignment: .bottom) { MiniBar(video: model.video, phone: model.phone, book: model.book, look: look) }
        .fullScreenCover(isPresented: $model.showPlayer) {
            NowPlayingView(phone: model.phone, book: model.book, together: model.together, tv: model.tvState)
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: $video.shown) {
            VideoScreen(video: video).environmentObject(model)
        }
        .transaction { if model.low && model.opts.still != false { $0.disablesAnimations = true } }
    }
}

/// Low vision's text size; full vision keeps the phone's own.
struct LowSize: ViewModifier {
    let size: DynamicTypeSize?
    func body(content: Content) -> some View {
        if let s = size { content.dynamicTypeSize(s) } else { content }
    }
}

/// While something plays and the player is closed: what it is, Play / Pause, and back to the player.
struct MiniBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var video: VideoModel
    @ObservedObject var phone: PhonePlayer
    @ObservedObject var book: BookPlayer
    let look: Look

    var body: some View {
        let title = video.active ? video.title : phone.active ? phone.title : book.active ? book.title : ""
        if !title.isEmpty && !video.shown && !model.showPlayer {
            HStack(spacing: 10) {
                Button {
                    if video.active { video.shown = true } else { model.showPlayer = true }
                } label: {
                    VStack(alignment: .leading) {
                        Text(title).bold().lineLimit(1)
                        Text(video.active ? "Playing on this phone" : "Now playing").font(.footnote).foregroundStyle(look.sub)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Now playing: \(title). Open the player")
                Button {
                    if video.active { video.playPause() } else { model.playPause() }
                } label: {
                    Image(systemName: (video.active ? video.paused : (phone.active ? phone.paused : book.paused)) ? "play.fill" : "pause.fill")
                        .font(.title2).frame(width: 52, height: 52)
                        .background(Circle().fill(look.btn)).foregroundStyle(look.btnFg)
                }
                .accessibilityLabel((video.active ? video.paused : (phone.active ? phone.paused : book.paused)) ? "Play" : "Pause")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16).fill(look.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(look.line, lineWidth: look.lineWidth))
            .padding(.horizontal, 10).padding(.bottom, 54)
            .foregroundStyle(look.fg)
        }
    }
}

// MARK: - Home

private let ROWS: [(String, String, Bool, [String: String])] = [
    ("continue", "Continue watching", true, [:]),
    ("recent", "New with audio description", true, [:]),
    ("shows", "New TV shows", false, ["ad": "all", "sort": "added", "desc": "1"]),
    ("movies", "New movies", false, ["ad": "all", "sort": "added", "desc": "1"]),
]

struct WatchHome: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: [String: [Card]] = [:]
    @State private var loaded = false

    var body: some View {
        let look = Look.of(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                InvitesSection(together: model.together).padding(.horizontal)
                if let hero = (rows["continue"] ?? []).first {
                    Hero(card: hero, look: look, head: "CONTINUE WATCHING")
                } else if let hero = (rows["recent"] ?? []).first {
                    Hero(card: hero, look: look, head: "NEW WITH AUDIO DESCRIPTION")
                }
                ForEach(ROWS, id: \.0) { r in
                    if let list = rows[r.0], !list.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(r.1).font(.title2.bold()).padding(.horizontal).accessibilityAddTraits(.isHeader)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(list) { c in
                                        NavigationLink { DetailPage(id: c.id, title: c.label) } label: {
                                            PosterCard(card: c, wide: r.2 || look.low, look: look)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                if loaded && rows.values.allSatisfy({ $0.isEmpty }) {
                    Text("Nothing here yet.").padding()
                }
            }
            .padding(.vertical)
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
        .navigationTitle("AD Player")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SearchView() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        for r in ROWS {
            var q: [String: String?] = ["kind": r.0]
            for (k, v) in r.3 { q[k] = v }
            if let got = try? await api.get("api/play/list", q, as: CardsResponse.self) { rows[r.0] = Array(got.items.prefix(20)) }
        }
        loaded = true
    }
}

struct Hero: View {
    @EnvironmentObject var model: AppModel
    let card: Card
    let look: Look
    let head: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.opts.posters != false || !look.low {
                AsyncImage(url: model.api?.media(nz(card.backdrop) ?? nz(card.thumb) ?? "/api/play/img/\(card.id)/Backdrop")) { img in
                    img.resizable().scaledToFill()
                } placeholder: { look.card }
                .frame(height: 210).clipped().accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(head).font(.caption.bold()).foregroundStyle(look.accent)
                Text(nz(card.seriesName) ?? nz(card.name) ?? card.label).font(.title.bold()).accessibilityAddTraits(.isHeader)
                if let r = card.resume, !r.isEmpty { Text("Resumes at \(r)").foregroundStyle(look.sub) }
                NavigationLink { DetailPage(id: card.id, title: card.label) } label: {
                    Text("More info").bold().frame(maxWidth: .infinity, minHeight: look.low ? 64 : 48)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.line, lineWidth: look.lineWidth))
                }
            }
            .padding(.horizontal)
        }
    }
}

struct PosterCard: View {
    @EnvironmentObject var model: AppModel
    let card: Card
    let wide: Bool
    let look: Look
    var body: some View {
        let w: CGFloat = wide ? (look.low ? 280 : 240) : (look.low ? 190 : 130)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if model.opts.posters != false || !look.low {
                    AsyncImage(url: model.api?.media(wide ? (nz(card.thumb) ?? nz(card.backdrop) ?? "/api/play/img/\(card.id)/Thumb") : (nz(card.poster) ?? "/api/play/img/\(card.id)/Primary"))) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { look.card }
                } else {
                    look.card.overlay(Text(card.label).bold().multilineTextAlignment(.center).padding(8))
                }
                if card.hasAD == true && card.type != "Book" {
                    Text("AD").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.75))).foregroundStyle(.white).padding(6)
                }
            }
            .frame(width: w, height: wide ? w * 9 / 16 : w * 1.5).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(look.low ? look.line : .clear, lineWidth: look.lineWidth))
            .overlay(alignment: .bottom) {
                if let p = card.pct, p > 0, p < 100 {
                    GeometryReader { g in
                        Rectangle().fill(look.accent).frame(width: g.size.width * CGFloat(p) / 100, height: 4).frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            Text(card.label).font(.subheadline.weight(.semibold)).lineLimit(look.low ? 4 : 2).frame(width: w, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.label + (card.hasAD == true ? ", audio description" : "") + ((card.resume ?? "").isEmpty ? "" : ", resumes at \(card.resume!)"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Shows and Movies

struct PosterGrid: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let title: String
    @State private var cards: [Card] = []
    @State private var withAD = true
    @State private var loading = true

    var body: some View {
        let look = Look.of(model)
        ScrollView {
            Toggle("With audio description only", isOn: $withAD).padding(.horizontal).onChange(of: withAD) { _ in Task { await load() } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: look.low ? 170 : 110), spacing: 12)], spacing: 16) {
                ForEach(cards) { c in
                    NavigationLink { DetailPage(id: c.id, title: c.label) } label: { PosterCard(card: c, wide: false, look: look) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
            if loading { ProgressView() } else if cards.isEmpty { Text("Nothing here.").padding() }
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
        .navigationTitle("\(title) (\(cards.count))")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        loading = true
        let q: [String: String?] = ["kind": kind, "sort": "title", "ad": withAD ? nil : "all"]
        if let r = try? await api.get("api/play/list", q, as: CardsResponse.self) { cards = r.items }
        loading = false
    }
}

// MARK: - A show's, movie's or episode's page

struct DetailPage: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let title: String
    @State private var item: Item?
    @State private var info: [String: Any] = [:]
    @State private var seasons: [Item] = []
    @State private var season: String = ""
    @State private var episodes: [Item] = []

    var body: some View {
        let look = Look.of(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.opts.posters != false || !look.low {
                    AsyncImage(url: model.api?.media(nz(info["backdrop"] as? String) ?? "/api/play/img/\(id)/Backdrop")) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { look.card }
                    .frame(height: 220).clipped().accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text((info["name"] as? String) ?? title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    if !metaLine.isEmpty { Text(metaLine).foregroundStyle(look.sub) }
                    if let it = item, it.type != "Series" {
                        BigButton(it.canResume ? "Resume" : "Play", main: true, look: look) { playItem(it, resume: it.canResume) }
                        BigButton("Play together", look: look) { model.play(it, resume: it.canResume, together: true) }
                        if it.canResume { BigButton("Start over", look: look) { playItem(it, resume: false) } }
                    }
                    if let o = info["overview"] as? String, !o.isEmpty { Text(o) }
                    if !seasons.isEmpty {
                        Text("Seasons").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(seasons) { s in
                                    Button(s.label) { season = s.id; Task { await loadEpisodes() } }
                                        .padding(.horizontal, 14).frame(minHeight: look.low ? 60 : 44)
                                        .background(RoundedRectangle(cornerRadius: 22).fill(season == s.id ? look.btn : look.card))
                                        .foregroundStyle(season == s.id ? look.btnFg : look.fg)
                                        .accessibilityAddTraits(season == s.id ? .isSelected : [])
                                }
                            }
                        }
                        ForEach(episodes) { e in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(e.label).bold()
                                if let r = e.resume, !r.isEmpty { Text("Resumes at \(r)").foregroundStyle(look.sub) }
                                HStack {
                                    BigButton(e.canResume ? "Resume" : "Play", main: true, look: look) { playItem(e, resume: e.canResume) }
                                        .accessibilityLabel((e.canResume ? "Resume " : "Play ") + e.label)
                                    BigButton("Together", look: look) { model.play(e, resume: e.canResume, together: true) }
                                        .accessibilityLabel("Play \(e.label) together")
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(look.card))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(look.low ? look.line : .clear, lineWidth: look.lineWidth))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let y = info["years"] as? String, !y.isEmpty { parts.append(y) }
        else if let y = info["year"] as? Int { parts.append(String(y)) }
        else if let y = info["year"] as? String, !y.isEmpty { parts.append(y) }
        if let l = info["length"] as? String, !l.isEmpty { parts.append(l) }
        if let r = info["rating"] as? String, !r.isEmpty { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    /// The video on this phone when she watches here; otherwise what she chose under Play on (a TV, or just the audio).
    private func playItem(_ it: Item, resume: Bool) {
        if model.isPhone && model.videoOK && model.preferVideo { model.video.start(it, resume: resume) }
        else { model.play(it, resume: resume) }
    }

    private func load() async {
        guard let api = model.api else { return }
        if let d = try? await api.raw("api/play/info", ["id": id]) {
            info = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            item = try? JSONDecoder().decode(Item.self, from: d)
            if let ss = info["seasons"], let sd = try? JSONSerialization.data(withJSONObject: ss) {
                seasons = (try? JSONDecoder().decode([Item].self, from: sd)) ?? []
            }
        }
        if item?.type == "Series" && seasons.isEmpty {
            seasons = (try? await api.get("api/play/list", ["kind": "seasons", "parent": id], as: ItemsResponse.self).items) ?? []
        }
        if season.isEmpty, let first = seasons.first { season = first.id; await loadEpisodes() }
    }

    private func loadEpisodes() async {
        guard let api = model.api, !season.isEmpty else { return }
        episodes = (try? await api.get("api/play/list", ["kind": "episodes", "parent": season], as: ItemsResponse.self).items) ?? []
    }
}

struct BigButton: View {
    let text: String
    var main = false
    let look: Look
    let action: () -> Void
    init(_ text: String, main: Bool = false, look: Look, action: @escaping () -> Void) {
        self.text = text; self.main = main; self.look = look; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(text).bold().frame(maxWidth: .infinity, minHeight: look.low ? 64 : 48)
                .background(RoundedRectangle(cornerRadius: 14).fill(main ? look.btn : look.card))
                .foregroundStyle(main ? look.btnFg : look.fg)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(main ? .clear : look.line, lineWidth: look.lineWidth))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Books

struct BooksTab: View {
    var body: some View {
        List {
            NavigationLink("Continue listening") { BookListView(kind: "books_continue", parent: nil, title: "Continue listening") }
            NavigationLink("All books") { BookListView(kind: "books_all", parent: nil, title: "All audiobooks") }
            NavigationLink("Series") { BookListView(kind: "books_series", parent: nil, title: "Audiobook series") }
            NavigationLink("Authors") { BookListView(kind: "books_authors", parent: nil, title: "Audiobook authors") }
        }
        .navigationTitle("Audiobooks")
    }
}

// MARK: - You

struct YouPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section { Text("Signed in as \(model.me?.name ?? "")") ; SignOutButton() } header: { Heading("Account") }
            if model.sightKnown { Section {
                SightChoices(current: model.sight).listRowBackground(Color.clear)
                if model.low {
                    Picker("Text size", selection: Binding(get: { model.opts.size ?? "large" }, set: { model.sightSave(["size": $0], said: "Text size: \($0).") })) {
                        Text("Normal").tag("normal"); Text("Large").tag("large"); Text("Larger").tag("larger"); Text("Largest").tag("largest")
                    }
                    Picker("Screen", selection: Binding(get: { model.opts.screen ?? "dark" }, set: { model.sightSave(["screen": $0], said: "Screen: \($0).") })) {
                        Text("Dark").tag("dark"); Text("Light").tag("light"); Text("Yellow on black").tag("yellow")
                    }
                    if model.me?.role != "listen" {
                        Toggle("Show the video when playing", isOn: Binding(get: { model.opts.video != false }, set: { model.sightSave(["video": $0 ? "1" : "0"], said: "Video: \($0 ? "on" : "off").") }))
                    }
                    Toggle("Turn off moving animations", isOn: Binding(get: { model.opts.still != false }, set: { model.sightSave(["still": $0 ? "1" : "0"], said: "Animations: \($0 ? "off" : "on").") }))
                    Toggle("Show posters and covers", isOn: Binding(get: { model.opts.posters != false }, set: { model.sightSave(["posters": $0 ? "1" : "0"], said: "Posters: \($0 ? "on" : "off").") }))
                }
            } header: { Heading("How you see the screen") } }
            Section {
                Picker("Play on", selection: $model.target) {
                    ForEach(model.playOnList, id: \.0) { d in Text(d.1).tag(d.0) }
                }
                .pickerStyle(.navigationLink)
                if model.isPhone && model.videoOK {
                    Toggle("Play the video on this phone", isOn: $model.preferVideo)
                }
                Button("Refresh the TV list") { Task { await model.refreshDevices(announce: true) } }
            } header: { Heading("Play on") }
            Section {
                NavigationLink("Downloads") { DownloadsView() }
                NavigationLink("Settings") { SetupView(first: false) }
            }
        }
        .navigationTitle("You")
    }
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

/// The AirPlay button (plays the video on an Apple TV straight from the phone).
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct VideoScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var video: VideoModel
    @State private var tracks: [TrackList.Track] = []

    var body: some View {
        VStack(spacing: 0) {                       // (the buttons above the picture: AVKit's own stay free)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button { video.shown = false } label: {
                        Image(systemName: "chevron.down").font(.title2.bold()).frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Close the player - it keeps playing")
                    Text(video.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        ForEach(tracks, id: \.self) { t in
                            Button((t.index == video.aidx ? "✓ " : "") + t.label) { if let i = t.index { video.switchAudio(i) } }
                        }
                    } label: {
                        Image(systemName: "captions.bubble").font(.title2).frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Sound track")
                    Button { video.stats.toggle(); model.say(video.stats ? "Stats for nerds on." : "Stats off.") } label: {
                        Image(systemName: "chart.bar").font(.title2).frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Stats for nerds")
                    .accessibilityAddTraits(video.stats ? .isSelected : [])
                    RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
                    Button { video.stop() } label: {
                        Image(systemName: "stop.fill").font(.title2).frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Stop")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
            }
            ZStack(alignment: .topLeading) {
                VideoPlayer(player: video.player).ignoresSafeArea(edges: .bottom)
                if video.stats { StatsPanel(video: video).padding(8) }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: video.item?.id) {
            guard let api = model.api, let it = video.item else { return }
            tracks = (try? await api.get("api/play/tracks", ["id": it.id], as: TrackList.self).audio) ?? []
        }
        .accessibilityAction(.escape) { video.shown = false }
        .accessibilityAction(.magicTap) { video.playPause() }
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
    @EnvironmentObject var model: AppModel
    @ObservedObject var video: VideoModel
    @State private var srv: VideoStats?
    @State private var rtt = 0
    @State private var lines: [String] = []

    var body: some View {
        Text(lines.joined(separator: "\n"))
            .font(.system(size: model.low ? 15 : 11, design: .monospaced))
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: 560, alignment: .leading)
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
