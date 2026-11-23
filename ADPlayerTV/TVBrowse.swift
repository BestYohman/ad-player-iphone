import SwiftUI

// MARK: - Pictures and cards

/// A picture from the PC (a plain colour while it loads, or when posters are off for low vision).
struct TVPic: View {
    @EnvironmentObject var model: AppModel
    let path: String?
    var body: some View {
        let look = Look.of(model)
        if let p = path, model.opts.posters != false || !look.low {
            AsyncImage(url: model.api?.media(p)) { img in img.resizable().scaledToFill() } placeholder: { look.card }
        } else {
            look.card
        }
    }
}

/// A poster (tall) or a picture (wide) that lifts when the remote is on it, with its name under it.
struct TVCard: View {
    @EnvironmentObject var model: AppModel
    let card: Card
    let wide: Bool

    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        let w: CGFloat = wide ? 420 : 250
        let h: CGFloat = wide ? w * 9 / 16 : w * 1.5
        NavigationLink {
            TVDetail(id: card.id, title: card.label)
        } label: {
            ZStack(alignment: .topLeading) {
                TVPic(path: wide ? (nz(card.thumb) ?? nz(card.backdrop) ?? "/api/play/img/\(card.id)/Thumb")
                                 : (nz(card.poster) ?? "/api/play/img/\(card.id)/Primary"))
                if look.low && model.opts.posters == false {
                    Text(card.label).font(sz.f(26, .bold)).multilineTextAlignment(.center).padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if card.hasAD == true {
                    Text("AD").font(.system(size: 20, weight: .heavy)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75))).foregroundStyle(.white).padding(10)
                }
                if let p = card.pct, p > 0, p < 100 {
                    GeometryReader { g in
                        Rectangle().fill(look.accent).frame(width: g.size.width * CGFloat(p) / 100, height: 6)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .buttonStyle(.card)
        .accessibilityLabel(card.label + (card.hasAD == true ? ", audio description" : "") + ((card.resume ?? "").isEmpty ? "" : ", resumes at \(card.resume!)"))
        .overlay(alignment: .bottomLeading) {
            Text(card.label).font(sz.f(22, .semibold)).lineLimit(look.low ? 3 : 2).foregroundStyle(look.fg)
                .frame(width: w, alignment: .leading)
                .alignmentGuide(.bottom) { d in d[.top] - 14 }
                .accessibilityHidden(true)
        }
        .padding(.bottom, 70 * sz.k)
    }
}

/// A row of cards that scrolls sideways.
struct TVRow: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let cards: [Card]
    let wide: Bool

    var body: some View {
        let sz = TVSize(model)
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(sz.f(38, .bold)).padding(.horizontal, 80).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 44) {
                    ForEach(cards) { c in TVCard(card: c, wide: wide) }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 24)
            }
            .focusSection()
        }
    }
}

// MARK: - Home

private let TV_ROWS: [(String, String, Bool, [String: String])] = [
    ("continue", "Continue watching", true, [:]),
    ("recent", "New with audio description", true, [:]),
    ("shows", "New TV shows", false, ["ad": "all", "sort": "added", "desc": "1"]),
    ("movies", "New movies", false, ["ad": "all", "sort": "added", "desc": "1"]),
]

struct TVHome: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: [String: [Card]] = [:]
    @State private var loaded = false

    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let hero = (rows["continue"] ?? []).first {
                    TVHero(card: hero, head: "CONTINUE WATCHING")
                } else if let hero = (rows["recent"] ?? []).first {
                    TVHero(card: hero, head: "NEW WITH AUDIO DESCRIPTION")
                }
                ForEach(TV_ROWS, id: \.0) { r in
                    if let list = rows[r.0], !list.isEmpty {
                        TVRow(title: r.1, cards: list, wide: r.2 || look.low)
                    }
                }
                if loaded && rows.values.allSatisfy({ $0.isEmpty }) {
                    Text("Nothing here yet.").font(sz.f(32)).padding(80)
                }
                if !loaded { ProgressView().padding(80) }
            }
            .padding(.bottom, 60)
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        for r in TV_ROWS {
            var q: [String: String?] = ["kind": r.0]
            for (k, v) in r.3 { q[k] = v }
            if let got = try? await api.get("api/play/list", q, as: CardsResponse.self) { rows[r.0] = Array(got.items.prefix(30)) }
        }
        loaded = true
    }
}

/// The big picture at the top of Home: what to carry on with.
struct TVHero: View {
    @EnvironmentObject var model: AppModel
    let card: Card
    let head: String

    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        ZStack(alignment: .bottomLeading) {
            TVPic(path: nz(card.backdrop) ?? nz(card.thumb) ?? "/api/play/img/\(card.id)/Backdrop")
                .frame(height: 560).frame(maxWidth: .infinity).clipped()
                .overlay(TVFade(look: look))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                Text(head).font(sz.f(24, .heavy)).foregroundStyle(look.accent)
                Text(nz(card.seriesName) ?? nz(card.name) ?? card.label).font(sz.f(58, .heavy)).lineLimit(2).accessibilityAddTraits(.isHeader)
                if nz(card.seriesName) != nil { Text(card.label).font(sz.f(30, .semibold)).lineLimit(2) }
                if let r = nz(card.resume) { Text("Resumes at \(r)").font(sz.f(28)).foregroundStyle(look.sub) }
                NavigationLink { TVDetail(id: card.id, title: card.label) } label: {
                    Text("More info").font(sz.f(30, .semibold)).padding(.horizontal, 20).tvLabel(look)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 80).padding(.bottom, 30)
            .frame(maxWidth: 1300, alignment: .leading)
        }
        .focusSection()
    }
}

/// The picture fades to the page's black at the bottom and on the left, so the words on it are easy to read.
struct TVFade: View {
    let look: Look
    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: look.bg.opacity(0), location: 0), .init(color: look.bg.opacity(0.4), location: 0.4),
                                   .init(color: look.bg.opacity(0.85), location: 0.72), .init(color: look.bg, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: look.bg.opacity(0.85), location: 0), .init(color: look.bg.opacity(0), location: 0.6)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }
}

// MARK: - Shows and Movies

struct TVGrid: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let title: String
    @State private var cards: [Card] = []
    @State private var withAD = true
    @State private var loading = true

    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 40) {
                    Text("\(title) (\(cards.count))").font(sz.f(52, .heavy)).accessibilityAddTraits(.isHeader)
                    Button { withAD.toggle(); Task { await load() } } label: {
                        Text("Audio description only: \(withAD ? "on" : "off")").font(sz.f(28, .semibold)).tvLabel(look)
                    }
                }
                .padding(.horizontal, 80)
                .focusSection()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: look.low ? 330 : 250), spacing: 44)], alignment: .leading, spacing: 30) {
                    ForEach(cards) { c in TVCard(card: c, wide: false) }
                }
                .padding(.horizontal, 80)
                .focusSection()                     // down from the button lands on the posters
                if loading { ProgressView().padding(80) } else if cards.isEmpty { Text("Nothing here.").font(sz.f(32)).padding(80) }
            }
            .padding(.vertical, 30)
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        loading = true
        let q: [String: String?] = ["kind": kind, "sort": "title", "ad": withAD ? nil : "all"]
        if let r = try? await api.get("api/play/list", q, as: CardsResponse.self) { cards = r.items }
        loading = false
    }
}

// MARK: - Search

struct TVSearch: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var cards: [Card] = []
    @State private var note = ""

    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !note.isEmpty { Text(note).font(sz.f(30)).padding(.horizontal, 80) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: look.low ? 330 : 250), spacing: 44)], alignment: .leading, spacing: 30) {
                    ForEach(cards) { c in TVCard(card: c, wide: false) }
                }
                .padding(.horizontal, 80)
            }
            .padding(.vertical, 30)
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
        .searchable(text: $text, prompt: "Shows, movies and episodes")
        .task(id: text) {
            let q = text.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { cards = []; note = ""; return }
            try? await Task.sleep(nanoseconds: 500_000_000)       // waits for the typing to stop
            guard !Task.isCancelled, let api = model.api else { return }
            do {
                cards = try await api.get("api/play/list", ["kind": "search", "q": q, "device": AppModel.phoneID], as: CardsResponse.self).items
                note = cards.isEmpty ? "Nothing found for \(q)." : ""
            } catch { note = error.localizedDescription }
        }
    }
}

// MARK: - A show's, movie's or episode's page

struct TVDetail: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let title: String
    @State private var item: Item?
    @State private var info: [String: Any] = [:]
    @State private var nextUp: Item?
    @State private var seasons: [Item] = []
    @State private var season = ""
    @State private var episodes: [Card] = []
    @State private var episodeItems: [String: Item] = [:]

    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        let isEp = item?.type == "Episode"
        let series = info["series_name"] as? String ?? ""
        let se = info["se"] as? Int
        let ep = info["ep"] as? Int
        ZStack(alignment: .topLeading) {
            TVPic(path: isEp ? (nz(info["thumb"] as? String) ?? nz(info["series_backdrop"] as? String) ?? "/api/play/img/\(id)/Primary")
                          : (nz(info["backdrop"] as? String) ?? nz(info["series_backdrop"] as? String) ?? "/api/play/img/\(id)/Backdrop"))
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .overlay(TVFade(look: look))
                .ignoresSafeArea()
                .accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // the show, the season and episode, and the name: all bold, on the faded part of the picture
                    VStack(alignment: .leading, spacing: 6) {
                        if isEp && !series.isEmpty {
                            Text(series).font(sz.f(38, .heavy))
                            if let se = se, let ep = ep { Text("Season \(se), episode \(ep)").font(sz.f(38, .heavy)) }
                        }
                        Text((info["name"] as? String) ?? title).font(sz.f(64, .heavy)).lineLimit(3)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    if !metaLine.isEmpty { Text(metaLine).font(sz.f(28)).foregroundStyle(look.sub) }
                    buttons
                    if let o = info["overview"] as? String, !o.isEmpty {
                        Text(o).font(sz.f(28)).lineLimit(look.low ? nil : 5).frame(maxWidth: 1250, alignment: .leading)
                    }
                    if !seasons.isEmpty { seasonsPart }
                }
                .padding(.horizontal, 80)
                .padding(.top, 330)
                .padding(.bottom, 60)
            }
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
        .task { await load() }
    }

    @ViewBuilder private var buttons: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        HStack(spacing: 30) {
            if let it = item, it.type == "Episode" || it.type == "Movie" {
                Button { model.video.start(it, resume: it.canResume) } label: {
                    Label(it.canResume ? "Resume from \(it.resume ?? "")" : "Play", systemImage: "play.fill").font(sz.f(30, .semibold)).tvLabel(look)
                }
                if it.canResume {
                    Button { model.video.start(it, resume: false) } label: { Text("Start over").font(sz.f(30, .semibold)).tvLabel(look) }
                }
            } else if let n = nextUp {
                Button { model.video.start(n, resume: n.canResume) } label: {
                    Label((n.canResume ? "Resume " : "Play ") + n.label, systemImage: "play.fill").font(sz.f(30, .semibold)).lineLimit(1).tvLabel(look)
                }
            }
            if item?.type == "Episode", let sid = info["series_id"] as? String, !sid.isEmpty {
                NavigationLink { TVDetail(id: sid, title: info["series_name"] as? String ?? "") } label: {
                    Text("Go to \((info["series_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "the show")").font(sz.f(30, .semibold)).tvLabel(look)
                }
            }
        }
        .focusSection()
    }

    @ViewBuilder private var seasonsPart: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        Text("Seasons").font(sz.f(38, .bold)).padding(.top, 20).accessibilityAddTraits(.isHeader)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(seasons) { s in
                    Button { season = s.id; Task { await loadEpisodes() } } label: {
                        Text(s.label).font(sz.f(28, season == s.id ? .heavy : .medium)).tvLabel(look)
                    }
                    .accessibilityAddTraits(season == s.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 16)
        }
        .focusSection()
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 44) {
                ForEach(episodes) { e in
                    Button {
                        if let it = episodeItems[e.id] { model.video.start(it, resume: it.canResume) }
                    } label: {
                        TVPic(path: nz(e.thumb) ?? "/api/play/img/\(e.id)/Primary")
                            .frame(width: 420, height: 236).clipped()
                            .overlay(alignment: .bottom) {
                                if let p = e.pct, p > 0, p < 100 {
                                    GeometryReader { g in
                                        Rectangle().fill(look.accent).frame(width: g.size.width * CGFloat(p) / 100, height: 6)
                                            .frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                }
                            }
                    }
                    .buttonStyle(.card)
                    .accessibilityLabel(((episodeItems[e.id]?.canResume ?? false) ? "Resume " : "Play ") + e.label)
                    .overlay(alignment: .bottomLeading) {
                        Text(e.label).font(sz.f(22, .semibold)).lineLimit(look.low ? 3 : 2)
                            .frame(width: 420, alignment: .leading)
                            .alignmentGuide(.bottom) { d in d[.top] - 14 }
                            .accessibilityHidden(true)
                    }
                    .padding(.bottom, 70 * sz.k)
                }
            }
            .padding(.vertical, 24)
        }
        .focusSection()
    }

    private var metaLine: String {
        var parts: [String] = []
        if let y = info["years"] as? String, !y.isEmpty { parts.append(y) }
        else if let y = info["year"] as? Int { parts.append(String(y)) }
        else if let y = info["year"] as? String, !y.isEmpty { parts.append(y) }
        if let l = info["length"] as? String, !l.isEmpty { parts.append(l) }
        if let r = info["rating"] as? String, !r.isEmpty { parts.append(r) }
        if let it = item, it.canResume, let r = it.resume { parts.append("Resumes at \(r)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let api = model.api else { return }
        if let d = try? await api.raw("api/play/info", ["id": id]) {
            info = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            item = try? JSONDecoder().decode(Item.self, from: d)
            if let ss = info["seasons"], let sd = try? JSONSerialization.data(withJSONObject: ss) {
                seasons = (try? JSONDecoder().decode([Item].self, from: sd)) ?? []
            }
            if let n = info["next_up"] as? [String: Any], let nd = try? JSONSerialization.data(withJSONObject: n) {
                nextUp = try? JSONDecoder().decode(Item.self, from: nd)
            }
        }
        if item?.type == "Series" && seasons.isEmpty {
            seasons = (try? await api.get("api/play/list", ["kind": "seasons", "parent": id], as: ItemsResponse.self).items) ?? []
        }
        if season.isEmpty, !seasons.isEmpty {
            season = seasons.first { !($0.played ?? false) }?.id ?? seasons[0].id
            await loadEpisodes()
        }
    }

    private func loadEpisodes() async {
        guard let api = model.api, !season.isEmpty else { return }
        guard let d = try? await api.raw("api/play/list", ["kind": "episodes", "parent": season]) else { return }
        episodes = (try? JSONDecoder().decode(CardsResponse.self, from: d).items) ?? []
        let its = (try? JSONDecoder().decode(ItemsResponse.self, from: d).items) ?? []
        episodeItems = Dictionary(its.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
