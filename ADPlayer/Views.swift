import SwiftUI

// Plain lists and buttons only - the standard iPhone controls, which VoiceOver reads best.

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if model.api == nil {
                SetupView(first: true)
            } else if model.needSignIn {
                SignInView()
            } else if !model.sightChosen {
                SightChooser()
            } else if model.sight == "none" {
                HomeView()
            } else {
                WatchRoot(video: model.video)
            }
        }
        .alert("Pair \(model.pairing?.name ?? "the Apple TV")", isPresented: Binding(get: { model.pairing != nil }, set: { if !$0 { model.pairing = nil } })) {
            TextField("Code", text: $model.pairCode).keyboardType(.numberPad)
            Button("Pair") { model.pairFinish() }
            Button("Cancel", role: .cancel) { model.pairing = nil }
        } message: {
            Text("Type the code the TV shows.")
        }
        .onChange(of: phase) { newPhase in
            model.scene(active: newPhase == .active)
        }
        // adplayer://join - from a "play together" notification: show the Join button straight away
        .onOpenURL { _ in Task { await model.together.pollInvites() } }
        .onAppear { model.scene(active: true) }
        // two-finger double tap: play or pause, here or on the TV
        .accessibilityAction(.magicTap) { model.playPause() }
    }
}

/// A section's name, read by VoiceOver as a heading (so the rotor's Headings jumps between the parts).
struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).accessibilityAddTraits(.isHeader)
    }
}

/// The buttons under a row: side by side, or one under the other when large text doesn't fit across.
struct ButtonRow<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { content() }
            VStack(alignment: .leading) { content() }
        }
    }
}

extension View {
    /// A VoiceOver action (swipe up or down on the row), only when it applies.
    @ViewBuilder func voiceOverAction(_ name: String, if on: Bool = true, _ run: @escaping () -> Void) -> some View {
        if on { accessibilityAction(named: Text(name), run) } else { self }
    }
}

/// "12 minutes of 45 minutes"
func placeText(_ pos: Double, _ total: Double) -> String {
    total > 0 ? "\(Speak.position(pos)) of \(Speak.duration(total))" : Speak.position(pos)
}

// MARK: - Address of the PC

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var offline = Offline.shared
    @Environment(\.dismiss) private var dismiss
    let first: Bool
    /// Opened from Settings in the watch layout (already inside its navigation): no second one around it.
    var pushed = false
    @State private var text = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        if pushed { content } else { NavigationStack { content } }
    }

    @ViewBuilder private var content: some View {
            Form {
                Section {
                    TextField("For example 192.168.1.20:5021", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { connect() }
                        .accessibilityLabel("Address of the PC")
                } header: {
                    Text("Address of the PC")
                } footer: {
                    Text("The same address as the AD Player web page: the PC's address and port 5021, or your web address for away from home. At home the app finds the PC by itself. The first time, iPhone asks to find devices on your local network - choose Allow.")
                }
                Section {
                    Button(busy ? "Connecting…" : "Connect") { connect() }
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !note.isEmpty {
                    Section { Text(note) }
                }
                if !first && !pushed && model.sightKnown {
                    // the audio-only layout's way to the watch layouts (low or full vision)
                    Section {
                        SightChoices(current: model.sight).listRowBackground(Color.clear)
                    } header: {
                        Text("How you see the screen")
                    }
                }
                if !first {
                    Section {
                        DelayPicker(together: model.together)
                    } footer: {
                        Text("Auto asks iPhone how late the headphones are (AirPods are about 0.2 seconds), so both of you hear it at the same moment.")
                    }
                    Section {
                        Toggle("Download on Wi-Fi only", isOn: $offline.wifiOnly)
                    } header: {
                        Text("Downloads")
                    } footer: {
                        Text(offline.wifiWait ? "Downloads are waiting for Wi-Fi." : "When off, downloads use mobile data too.")
                    }
                    Section {
                        Text(model.atHome ? "Connected at home, straight to the PC." : "Connected through the address above.")
                        if let name = model.me?.name, !name.isEmpty, !model.needSignIn {
                            Text("Signed in as \(name).")
                            SignOutButton { dismiss() }
                        }
                    }
                }
            }
            .accessibilityAction(.escape) { dismiss() }
            .navigationTitle(first ? "Set up AD Player" : pushed ? "The PC and downloads" : "Settings")
            .toolbar {
                if !first && !pushed {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear { if text.isEmpty { text = model.server } }
    }

    private func connect() {
        guard !busy else { return }
        busy = true
        note = ""
        let entered = text
        Task {
            let problem = await model.connect(entered)
            busy = false
            if let problem = problem {
                note = problem
                model.announce(problem)
            } else {
                model.announce("Connected.")
                if !first && !pushed { dismiss() }
            }
        }
    }
}

struct DelayPicker: View {
    @ObservedObject var together: Together

    var body: some View {
        Picker("Headphone delay when playing together", selection: $together.delayChoice) {
            ForEach(Together.delays, id: \.0) { d in
                Text(d.1).tag(d.0)
            }
        }
    }
}

/// Sign out, asked first: she'd have to type the password again.
struct SignOutButton: View {
    @EnvironmentObject var model: AppModel
    var done: () -> Void = {}
    @State private var ask = false

    var body: some View {
        Button("Sign out") { ask = true }
            .confirmationDialog("Sign out?", isPresented: $ask, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { model.signOut(); done() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need the password to sign in again.")
            }
    }
}

// MARK: - Signing in

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var note = ""
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("User name", text: $user)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { go() }
                } header: {
                    Text("Your Emby user name and password")
                } footer: {
                    Text("The same as for Emby. The phone stays signed in.")
                }
                Section {
                    Button(busy ? "Signing in…" : "Sign in") { go() }
                        .disabled(busy || user.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !note.isEmpty {
                    Section { Text(note) }
                }
                Section {
                    Button("Change the address of the PC") { showSetup = true }
                }
            }
            .navigationTitle("Sign in")
            .sheet(isPresented: $showSetup) {
                SetupView(first: false).environmentObject(model)
            }
        }
    }

    private func go() {
        guard !busy else { return }
        let u = user.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        busy = true
        note = ""
        Task {
            let problem = await model.signIn(user: u, password: password)
            busy = false
            if let problem = problem {
                note = problem
                model.announce(problem)
            }
        }
    }
}

// MARK: - Home: the same order as the AD Player web page - where to play, what to play, then that kind's lists

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @AppStorage("ad_what") private var what = "shows"          // books / shows / movies, like the web page's Play buttons
    @State private var query = ""
    @State private var searchFor: String?
    @State private var progress: [Item] = []
    @State private var progressLoading = false
    @State private var progressProblem: String?
    @State private var progressAt: Date?
    @State private var progressKind = ""

    private var kinds: [(String, String)] {
        (model.booksSetUp ? [("books", "Audiobooks")] : []) + [("shows", "Shows"), ("movies", "Movies")]
    }
    private var shown: String { model.booksSetUp || what != "books" ? what : "shows" }
    private var movies: Bool { shown == "movies" }

    var body: some View {
        NavigationStack {
            List {
                InvitesSection(together: model.together)
                NowPlayingRow(phone: model.phone, book: model.book, together: model.together, tv: model.tvState)

                Section {
                    Picker("Play on", selection: $model.target) {
                        ForEach(model.playOnList, id: \.0) { d in
                            Text(d.1).tag(d.0)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Button("Refresh the TV list") {
                        Task { await model.refreshDevices(announce: true) }
                    }

                    Picker("Play", selection: Binding(get: { shown }, set: { what = $0; query = "" })) {
                        ForEach(kinds, id: \.0) { k in Text(k.1).tag(k.0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Play")
                } header: {
                    Heading("TV")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.otherDevices.isEmpty {
                            Text("Connected but can't be controlled from here: \(model.otherDevices.joined(separator: ", ")). Use the Emby app on that TV instead.")
                        }
                    }
                }

                if shown == "books" {
                    Section {
                        TextField("Search audiobooks", text: $query)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { search() }
                        Button("Search") { search() }
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                        NavigationLink("All books") { BookListView(kind: "books_all", parent: nil, title: "All audiobooks") }
                        NavigationLink("Series") { BookListView(kind: "books_series", parent: nil, title: "Audiobook series") }
                        NavigationLink("Authors") { BookListView(kind: "books_authors", parent: nil, title: "Audiobook authors") }
                    } header: {
                        Heading("Audiobooks")
                    } footer: {
                        Text("A title, author, narrator or series.")
                    }
                    Section {
                        if model.continueBooks.isEmpty {
                            Text(model.booksNote.isEmpty ? "Nothing in progress." : model.booksNote)
                        }
                        ForEach(model.continueBooks) { item in BookRow(item: item) }
                    } header: {
                        Heading("Continue listening")
                    }
                } else {
                    Section {
                        TextField(movies ? "Search movies" : "Search shows", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { search() }
                        Button("Search") { search() }
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                        NavigationLink(movies ? "Movies with description" : "Shows with description") {
                            ItemListView(kind: shown, parent: nil, title: movies ? "Movies with description" : "Shows with description")
                        }
                        NavigationLink("Favorites") {
                            ItemListView(kind: "favorites_\(shown)", parent: nil, title: movies ? "Favorite movies" : "Favorite shows",
                                         empty: "No favorites yet. Use Add to favorites on a show or movie.")
                        }
                        NavigationLink(movies ? "Movies without description" : "Shows without description") {
                            ItemListView(kind: "noad_\(shown)", parent: nil,
                                         title: movies ? "Movies without description" : "Shows without description")
                        }
                        NavigationLink("Requests for audio description") {
                            ItemListView(kind: "requests", parent: nil, title: "Requests for audio description",
                                         empty: "Nothing asked for yet. Shows and movies without description have an Ask for audio description button.")
                        }
                    } header: {
                        Heading(movies ? "Movies" : "Shows")
                    } footer: {
                        if !movies { Text("For one episode, type the show, season and episode, like: friends 4 2") }
                    }
                    Section {
                        if progress.isEmpty {
                            Text(progressLoading ? "Loading…" : (progressProblem ?? "Nothing in progress."))
                        } else if let problem = progressProblem {
                            Text(problem)
                        }
                        ForEach(progress) { item in ItemRow(item: item) }
                    } header: {
                        Heading(movies ? "Movies in progress" : "Shows in progress")
                    }
                }

                Section {
                    NavigationLink { DownloadsView() } label: { DownloadsLabel(offline: Offline.shared) }
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Episodes, movies and audiobooks kept on this phone, to play with no connection.")
                }

                if !model.message.isEmpty {
                    Section {
                        Text(model.message)
                    } header: {
                        Heading("Last message")
                    }
                }

                Section {
                    if let name = model.me?.name, !name.isEmpty {
                        Text("Signed in as \(name).")
                    }
                    Button("Settings") { showSettings = true }
                    if model.me?.admin == true {
                        NavigationLink("Server settings") { ServerSettingsView() }     // (whoever runs the server)
                    }
                    if let name = model.me?.name, !name.isEmpty, !model.needSignIn {
                        SignOutButton()
                    }
                } header: {
                    Heading("You")
                }
            }
            .navigationTitle("AD Player")
            .navigationDestination(isPresented: Binding(get: { searchFor != nil }, set: { if !$0 { searchFor = nil } })) {
                if let q = searchFor {
                    if shown == "books" { BookSearchView(initial: q) } else { SearchView(kind: "search_\(shown)", initial: q) }
                }
            }
            // once when it opens or the kind changes; coming back from a list it's only fetched again after 5 minutes
            .task(id: shown) { await loadProgress(ifOld: true) }
            .onChange(of: model.continueItems) { _ in Task { await loadProgress() } }   // after Stop, a TV finishing…
            .refreshable {
                let before = progressProblem
                await model.refreshAll()
                await loadProgress()
                if let p = progressProblem, before != nil { model.announce(p) }     // (a new problem is said already)
            }
            .sheet(isPresented: $showSettings) {
                SetupView(first: false).environmentObject(model)
            }
            .fullScreenCover(isPresented: $model.showPlayer) {
                NowPlayingView(phone: model.phone, book: model.book, together: model.together, tv: model.tvState)
                    .environmentObject(model)
            }
        }
        .id(model.homeToken)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { model.announce("Type something to search for."); return }
        searchFor = q
    }

    /// ifOld: only when it hasn't been fetched in the last 5 minutes.
    private func loadProgress(ifOld: Bool = false) async {
        guard shown != "books" else { return }
        let kind = shown
        if ifOld, progressKind == kind, let at = progressAt, Date().timeIntervalSince(at) < 300 { return }
        if progressKind != kind { progress = []; progressProblem = nil }
        progressLoading = true
        defer { progressLoading = false }
        do {
            let items = try await model.list(kind: "continue_\(kind)")
            guard kind == shown else { return }
            progress = items
            progressProblem = nil
            progressAt = Date()
            progressKind = kind
        } catch {
            guard !Task.isCancelled, kind == shown else { return }
            // the real reason, not "Nothing in progress" (said once, when it starts going wrong)
            let was = progressProblem
            progressProblem = error.localizedDescription
            progressKind = kind
            progressAt = nil
            if was == nil { model.announce(error.localizedDescription) }
        }
    }
}

/// "Bob wants to play … together" with a Join button, at the top of Home.
struct InvitesSection: View {
    @ObservedObject var together: Together

    var body: some View {
        if !together.active && !together.invites.isEmpty {
            Section {
                ForEach(together.invites) { inv in
                    Text(inv.line)
                    Button("Join \(inv.invitedBy ?? inv.by): \(inv.title)") { together.join(inv) }
                    Button("Not now") { together.decline(inv) }
                        .accessibilityLabel("Not now: \(inv.by), \(inv.title)")
                }
            } header: {
                Heading("Play together")
            }
        }
    }
}

/// "Now playing: …" at the top of Home, to get back to the controls.
struct NowPlayingRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var phone: PhonePlayer
    @ObservedObject var book: BookPlayer
    @ObservedObject var together: Together
    @ObservedObject var tv: TVState

    var body: some View {
        if let title = nowTitle {
            Section {
                Button("Now playing: \(title)") { model.showPlayer = true }
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private var nowTitle: String? {
        if together.active { return together.room?.title ?? "playing together" }
        if model.isPhone {
            if book.active { return book.title }
            return phone.active ? phone.title : nil
        }
        if let s = tv.status, s.playing { return s.title ?? s.text }
        return nil
    }
}

// MARK: - Lists

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var offline = Offline.shared
    let item: Item
    @State private var favorite: Bool?
    @State private var requested: Bool?

    private var fav: Bool { favorite ?? (item.favorite ?? false) }
    private var asked: Bool { requested ?? (item.requested ?? false) }
    private var canFavorite: Bool { item.type == "Series" || item.type == "Movie" }
    private var canAsk: Bool { item.hasAD == false }
    private var downloadable: Bool { item.type == "Episode" || item.type == "Movie" || item.type == "Video" }

    /// What VoiceOver reads for the row: its name, and whether it's on the phone.
    private var rowLabel: String {
        guard downloadable, let s = offline.find(item.id, "audio") else { return item.spoken }
        let state: String
        switch s.state {
        case "done": state = "downloaded"
        case "failed": state = "didn't download"
        default: state = "downloading"
        }
        return item.spoken + ", " + state
    }

    var body: some View {
        switch item.type ?? "" {
        case "Request":
            Text("\(item.label): \(item.text ?? ""). Asked for on \(item.date ?? "").")
        case "Series":
            // one VoiceOver stop: the show; its buttons are actions (swipe up or down)
            VStack(alignment: .leading, spacing: 6) {
                NavigationLink(item.spoken) {
                    ItemListView(kind: "seasons", parent: item.id, title: "\(item.label) seasons")
                }
                .voiceOverAction(favoriteName, if: canFavorite) { toggleFavorite() }
                .voiceOverAction(askName, if: canAsk) { ask() }
                ButtonRow { actionButtons }
                    .accessibilityHidden(true)
            }
        case "Season":
            NavigationLink(item.spoken) {
                ItemListView(kind: "episodes", parent: item.id, title: item.label)
            }
        default:
            // one VoiceOver stop: the row plays it; the buttons beside it are actions (swipe up or down)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.play(item, resume: true)
                } label: {
                    Text(item.spoken)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(rowLabel)
                .accessibilityHint(item.canResume ? "Plays from where you left off." : "Plays it.")
                .voiceOverAction("Play together") { model.play(item, resume: true, together: true) }
                .voiceOverAction("Start over", if: item.canResume) { model.play(item, resume: false) }
                .voiceOverAction(DownloadButton.text(offline, offline.find(item.id, "audio")), if: downloadable) { download() }
                .voiceOverAction(favoriteName, if: canFavorite) { toggleFavorite() }
                .voiceOverAction(askName, if: canAsk) { ask() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("Play together") { model.play(item, resume: true, together: true) }
                            .buttonStyle(.bordered)
                        if item.canResume {
                            Button("Start over") { model.play(item, resume: false) }
                                .buttonStyle(.bordered)
                        }
                        if downloadable {
                            DownloadButton(offline: offline, id: item.id, kind: "audio", label: item.label) { download() }
                        }
                        actionButtons
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private var favoriteName: String { fav ? "Remove from favorites" : "Add to favorites" }
    private var askName: String { asked ? "Asked for audio description" : "Ask for audio description" }

    private func download() {
        DownloadButton.press(offline, id: item.id, kind: "audio", label: item.label) { offline.download(item) }
    }

    private func toggleFavorite() {
        let on = !fav
        Task {
            if let m = await model.setFavorite(item, on: on) { favorite = on; model.announce(m) }
        }
    }

    private func ask() {
        Task {
            if let m = await model.requestAD(item) { requested = true; model.announce(m) }
        }
    }

    /// Add to favorites (shows and movies) and Ask for audio description (ones without it), as on the web page.
    @ViewBuilder private var actionButtons: some View {
        if canFavorite {
            Button(favoriteName) { toggleFavorite() }
                .buttonStyle(.bordered)
        }
        if canAsk {
            Button(askName) { ask() }
                .buttonStyle(.bordered)
        }
    }
}

struct ItemListView: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let parent: String?
    let title: String
    let empty: String
    @State private var items: [Item] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var view: ListView
    @State private var loadedAt: Date?
    @State private var showSort = false

    init(kind: String, parent: String?, title: String, empty: String = "Nothing here.") {
        self.kind = kind
        self.parent = parent
        self.title = title
        self.empty = empty
        // the saved sort and filters are there before the first load (so it loads once, and says nothing)
        _view = State(initialValue: ListView.applies(kind) ? ListView.load(kind) : ListView())
    }

    private var sortable: Bool { ListView.applies(kind) }

    var body: some View {
        List {
            if sortable {
                Section {
                    Button(view.summary) { showSort = true }
                        .accessibilityHint("Opens sort by and the filters.")
                }
            }
            Section {
                if loading && items.isEmpty {
                    Text("Loading…")
                } else if let problem = problem {
                    Text(problem)
                } else if items.isEmpty {
                    Text(sortable && view.filtersOn > 0 ? "Nothing matches these filters." : empty)
                }
                ForEach(items) { item in
                    ItemRow(item: item)
                }
            }
        }
        .navigationTitle(items.isEmpty ? title : "\(title) (\(items.count))")
        .homeBar()
        // once when it opens; back from a deeper list it's only fetched again after 5 minutes (or pull to refresh)
        .task { if loadedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $showSort) {
            SortFilterView(kind: kind, view: $view).environmentObject(model)
        }
        .onChange(of: view) { v in
            v.save(kind)
            Task { await load(announce: true) }
        }
    }

    private func load(announce: Bool = false) async {
        loading = true
        do {
            items = try await model.list(kind: kind, parent: parent, view: sortable ? view : nil)
            problem = nil
            loadedAt = Date()
            if announce {
                model.announce(items.isEmpty ? (view.filtersOn > 0 ? "Nothing matches these filters." : "Nothing here.")
                                             : "\(items.count) item\(items.count == 1 ? "" : "s").")
            }
        } catch {
            if Task.isCancelled { loading = false; return }      // (left the screen before it came)
            problem = error.localizedDescription
            loadedAt = nil
            if announce { model.announce(error.localizedDescription) }
        }
        loading = false
    }
}

/// Sort by and the filters for a shows or movies list (as on the web page).
struct SortFilterView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: String
    @Binding var view: ListView
    @State private var choices: FilterChoices?

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort") {
                    Picker("Sort by", selection: Binding(get: { view.sort }, set: { k in
                        view.sort = k
                        view.desc = ListView.sorts.first { $0.0 == k }?.2 ?? false
                    })) {
                        ForEach(ListView.sorts, id: \.0) { s in Text(s.1).tag(s.0) }
                    }
                    if view.sort != "random" {
                        let w = ListView.ways(view.sort)
                        Picker("Order", selection: $view.desc) {
                            Text(w.0).tag(false)
                            Text(w.1).tag(true)
                        }
                    }
                }
                Section {
                    Picker("Watched", selection: $view.state) {
                        ForEach(ListView.states, id: \.0) { s in Text(s.1).tag(s.0) }
                    }
                    if !kind.hasPrefix("favorites") {
                        Toggle("Favorites only", isOn: $view.fav)
                    }
                    Picker("Genre", selection: $view.genre) {
                        Text("Any").tag("")
                        ForEach(options(choices?.genres, view.genre), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Parental rating", selection: $view.rating) {
                        Text("Any").tag("")
                        ForEach(options(choices?.ratings, view.rating), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Year", selection: $view.year) {
                        Text("Any").tag("")
                        ForEach(options(choices?.years, view.year), id: \.self) { Text($0).tag($0) }
                    }
                    if view.filtersOn > 0 {
                        Button("Clear filters") {
                            view = ListView(sort: view.sort, desc: view.desc)
                            model.announce("Filters cleared.")
                        }
                    }
                } header: {
                    Text("Filters")
                } footer: {
                    if choices == nil { Text("Getting the genres, ratings and years…") }
                }
            }
            .accessibilityAction(.escape) { dismiss() }
            .navigationTitle("Sort and filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { choices = await model.filterChoices(kind: kind) ?? FilterChoices.empty }
        }
    }

    /// The list's choices, plus the one chosen before (so it still shows if it's no longer there).
    private func options(_ list: [String]?, _ chosen: String) -> [String] {
        let l = list ?? []
        return chosen.isEmpty || l.contains(chosen) ? l : [chosen] + l
    }
}

/// Home at the bottom of the screen: back to the start from any list.
struct HomeBar: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .accessibilityAction(.magicTap) { model.playPause() }
            .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    model.goHome()
                } label: {
                    Label("Home", systemImage: "house")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityHint("Goes back to the start.")
            }
        }
    }
}

extension View {
    func homeBar() -> some View { modifier(HomeBar()) }
}

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    var kind = "search"
    var initial = ""
    @State private var text = ""
    @State private var items: [Item] = []
    @State private var note = "Type a show, movie or episode - for example friends 4 2 - then press Search."
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                TextField("Search", text: $text)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { run() }
                Button("Search") { run() }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(note)
            }
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        ItemRow(item: item)
                    }
                } header: {
                    Heading("Found")
                }
            }
        }
        .navigationTitle("Search")
        .homeBar()
        .onAppear { if !initial.isEmpty && text.isEmpty { text = initial; run() } else if initial.isEmpty { focused = true } }
    }

    private func run() {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        focused = false
        note = "Searching…"
        Task {
            do {
                items = try await model.list(kind: kind, query: q)
                note = items.isEmpty ? "Nothing found for \(q)." : "\(items.count) found."
            } catch {
                items = []
                note = error.localizedDescription
            }
            model.announce(note)
        }
    }
}

// MARK: - Downloads

struct DownloadsLabel: View {
    @ObservedObject var offline: Offline

    var body: some View {
        let n = offline.items.count
        let going = offline.items.filter { $0.state == "preparing" || $0.state == "downloading" }.count
        Text("Downloads" + (n == 0 ? "" : ", \(n)") + (going > 0 ? ", \(going) on the way" : ""))
    }
}

/// Download beside Play: says how it's going, and does nothing more once it's on its way.
struct DownloadButton: View {
    @ObservedObject var offline: Offline
    let id: String
    let kind: String
    let label: String
    let start: () -> Void

    /// The button's words (also the row's VoiceOver action).
    static func text(_ offline: Offline, _ s: Offline.Saved?) -> String {
        guard let s = s else { return "Download" }
        switch s.state {
        case "done": return "Downloaded"
        case "failed": return "Download again"
        case "preparing": return "Getting ready" + (s.progress > 0 ? " \(s.progress)%" : "")
        default: return (offline.wifiWait ? "Waiting for Wi-Fi" : "Downloading") + (s.progress > 0 ? " \(s.progress)%" : "")
        }
    }

    /// Starts it, or (once it's on its way) says how it's going.
    static func press(_ offline: Offline, id: String, kind: String, label: String, start: () -> Void) {
        if let s = offline.find(id, kind), s.state != "failed" { offline.say("\(label): \(s.stateText).") } else { start() }
    }

    var body: some View {
        let s = offline.find(id, kind)
        Button(DownloadButton.text(offline, s)) {
            DownloadButton.press(offline, id: id, kind: kind, label: label, start: start)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(s == nil ? "Download \(label)" : "\(label): \(s!.stateText)")
        .accessibilityHint(s == nil ? "Keeps it on this phone, to play with no connection." : "")
    }
}

struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var offline = Offline.shared
    @State private var removing: Offline.Saved?

    var body: some View {
        List {
            if offline.items.isEmpty {
                Text("Nothing downloaded yet. Use Download beside an episode, a movie or an audiobook.")
            }
            ForEach(Array(offline.items.reversed())) { s in
                // one VoiceOver stop: the row plays it; Try again and Remove are actions (swipe up or down)
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if s.done { model.playDownloaded(s) } else { offline.say("\(s.title): \(s.stateText).") }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).foregroundColor(.primary)
                            Text("\(s.kindText). \(s.stateText).").font(.footnote).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(s.done ? "Plays it on this phone." : "")
                    .voiceOverAction("Try again", if: s.state == "failed") { offline.retry(s) }
                    .voiceOverAction(s.done ? "Remove" : "Stop downloading") { removing = s }
                    ButtonRow {
                        if s.state == "failed" {
                            Button("Try again") { offline.retry(s) }
                                .buttonStyle(.bordered)
                        }
                        Button(s.done ? "Remove" : "Stop", role: .destructive) { removing = s }
                            .buttonStyle(.bordered)
                    }
                    .accessibilityHidden(true)
                }
            }
            if !offline.items.isEmpty {
                let total = offline.items.filter { $0.done }.reduce(Int64(0)) { $0 + $1.bytes }
                if total > 0 {
                    Section { Text("On this phone: \(Offline.size(total)).") }
                }
            }
        }
        .navigationTitle("Downloads")
        .homeBar()
        .onAppear { offline.resume() }
        // asked first: it would have to be downloaded again
        .confirmationDialog(removing?.done == false ? "Stop this download?" : "Remove this download?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { s in
            Button(s.done ? "Remove" : "Stop", role: .destructive) { offline.remove(s); removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { s in
            Text(s.done ? "\(s.title) is taken off this phone." : "\(s.title) stops downloading.")
        }
    }
}

// MARK: - Now playing: only the controls

struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var phone: PhonePlayer
    @ObservedObject var book: BookPlayer
    @ObservedObject var together: Together
    @ObservedObject var tv: TVState

    var body: some View {
        NavigationStack {
            List {
                if together.active {
                    TogetherControls(together: together, book: book, phone: phone)
                } else {
                    soloControls
                }
                Section {
                    Button("Where am I?") { model.whereAmI() }
                    Button("Find something else") { model.showPlayer = false }
                }
            }
            .sheet(isPresented: Binding(get: { together.inviting != nil }, set: { if !$0 { together.inviting = nil } })) {
                InvitePicker(together: together)
            }
            // VoiceOver's escape (two-finger scrub) closes it, like Find something else
            .accessibilityAction(.escape) { model.showPlayer = false }
            .navigationTitle("Now playing")
            .navigationBarTitleDisplayMode(.inline)
            .homeBar()
        }
    }

    @ViewBuilder private var soloControls: some View {
                Section {
                    // swipe up or down: forward or back 30 seconds
                    Text(statusText)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityValue(place.map { placeText($0.0, $0.1) } ?? "")
                        .accessibilityAdjustableAction { d in
                            switch d {
                            case .increment: move(30)
                            case .decrement: move(-30)
                            @unknown default: break
                            }
                        }
                }
                if model.isPhone && book.active {
                    bookControls
                } else if model.isPhone {
                    phoneControls
                } else if tv.status?.book == true {
                    tvBookControls
                } else {
                    tvControls
                }
    }

    private var statusText: String {
        if model.isPhone { return book.active ? book.statusText : phone.statusText }
        return tv.status?.text ?? "Checking the TV…"
    }

    /// Where it is and how long it is, in seconds.
    private var place: (Double, Double)? {
        if model.isPhone && book.active { return book.preparing ? nil : (book.position, book.duration) }
        if model.isPhone { return phone.active && !phone.preparing ? (phone.position, phone.duration) : nil }
        guard let s = tv.status, s.playing, let pos = s.posTicks else { return nil }
        return (pos / 10_000_000, (s.runTicks ?? 0) / 10_000_000)
    }

    private func move(_ by: Double) {
        if model.isPhone && book.active { book.skip(by, quiet: true) }       // (VoiceOver reads the new place)
        else if model.isPhone { phone.skip(by, quiet: true) }
        else { model.tv(by < 0 ? "back30" : "fwd30") }
    }

    @ViewBuilder private var phoneControls: some View {
        Section {
            Button(phone.paused ? "Play" : "Pause") { phone.togglePause() }
                .disabled(phone.preparing)
            Button("Back 30 seconds") { phone.skip(-30) }
                .disabled(phone.preparing)
            Button("Forward 30 seconds") { phone.skip(30) }
                .disabled(phone.preparing)
            if phone.hasNext {
                Button("Next episode") { phone.next() }
            }
            Button("Stop") { phone.stop() }
        }
    }

    @ViewBuilder private var tvControls: some View {
        let s = tv.status
        Section {
            Button(tv.paused ? "Play" : "Pause") { model.tvPlayPause() }
            Button("Back 30 seconds") { model.tv("back30") }
            Button("Forward 30 seconds") { model.tv("fwd30") }
            if s?.hasNext == true {
                Button("Next episode") { model.tv("next") }
            }
            if s?.ad == false && s?.hasAD == true {
                Button("Turn on audio description") { model.tv("ad") }
            }
            Button("Stop") { model.tv("stop") }
        }
        Section {
            Button("Volume down") { model.tv("voldown") }
            Button("Volume up") { model.tv("volup") }
        } header: {
            Heading("TV volume")
        }
    }

    @ViewBuilder private var bookControls: some View {
        Section {
            Button(book.paused ? "Play" : "Pause") { book.togglePause() }
                .disabled(book.preparing)
            Button("Back 30 seconds") { book.skip(-30) }
                .disabled(book.preparing)
            Button("Forward 30 seconds") { book.skip(30) }
                .disabled(book.preparing)
            if !book.chapters.isEmpty {
                Button("Previous chapter") { book.previousChapter() }
                    .disabled(book.preparing)
                Button("Next chapter") { book.nextChapter() }
                    .disabled(book.preparing)
                NavigationLink("Chapters") { ChapterList(bookID: book.bookID, bookTitle: book.title) }
            }
            Button("Add a bookmark here") { model.addBookmark(bookID: book.bookID, at: book.currentTime()) }
                .disabled(book.preparing)
            NavigationLink("Bookmarks") { BookmarkList(bookID: book.bookID, bookTitle: book.title) }
            Button("Stop") { book.stop() }
        }
        Section {
            Picker("Speed", selection: Binding(get: { book.speed }, set: { book.setSpeed($0) })) {
                ForEach(BookPlayer.speeds, id: \.self) { v in
                    Text(BookPlayer.speedLabel(v)).tag(v)
                }
            }
            Picker("Sleep timer", selection: Binding(get: { book.sleepChoice }, set: { book.setSleep($0) })) {
                ForEach(BookPlayer.sleepChoices, id: \.value) { c in
                    Text(c.label).tag(c.value)
                }
            }
        } header: {
            Heading("Listening")
        }
    }

    @ViewBuilder private var tvBookControls: some View {
        let s = tv.status
        Section {
            Button(tv.paused ? "Play" : "Pause") { model.tvPlayPause() }
            Button("Back 30 seconds") { model.tv("back30") }
            Button("Forward 30 seconds") { model.tv("fwd30") }
            if s?.hasPrev == true {
                Button("Previous chapter") { model.tv("prev") }
            }
            if s?.hasNext == true {
                Button("Next chapter") { model.tv("next") }
            }
            if let id = s?.bookID, s?.hasPrev == true {
                NavigationLink("Chapters") { ChapterList(bookID: id, bookTitle: s?.title ?? "") }
            }
            if let id = s?.bookID {
                Button("Add a bookmark here") { model.addBookmark(bookID: id, at: (s?.posTicks ?? 0) / 10_000_000) }
                NavigationLink("Bookmarks") { BookmarkList(bookID: id, bookTitle: s?.title ?? "") }
            }
            Button("Stop") { model.tv("stop") }
        }
        Section {
            Picker("Sleep timer", selection: Binding(get: { s?.sleepVal ?? "off" }, set: { model.tv("sleep:" + $0) })) {
                ForEach(BookPlayer.sleepChoices, id: \.value) { c in
                    Text(c.label).tag(c.value)
                }
            }
        } header: {
            Heading("Listening")
        }
        Section {
            Button("Volume down") { model.tv("voldown") }
            Button("Volume up") { model.tv("volup") }
        } header: {
            Heading("TV volume")
        }
    }
}

/// The buttons while playing together: they work the shared clock, so both phones follow.
struct TogetherControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var together: Together
    @ObservedObject var book: BookPlayer
    @ObservedObject var phone: PhonePlayer          // (getting the audio ready shows how far it's got)
    @State private var askStop = false

    var body: some View {
        Section {
            // who's in it, and what each phone is doing
            ForEach(Array((together.room?.people ?? []).enumerated()), id: \.offset) { _, p in
                Text("\(p.me == true ? "You" : p.name): \(p.stateText ?? p.state ?? "")")
            }
            Button("Invite people") { Task { await together.inviteOpen() } }
            if let ev = together.room?.events, !ev.isEmpty {
                NavigationLink("What happened") { TogetherEvents(together: together) }
            }
        } header: {
            Heading("Playing together")
        }
        Section {
            // swipe up or down: forward or back 30 seconds, for everyone
            Text(together.statusText)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityValue(placeText(together.place.pos, together.place.total))
                .accessibilityAdjustableAction { d in
                    switch d {
                    case .increment: together.command("fwd30")
                    case .decrement: together.command("back30")
                    @unknown default: break
                    }
                }
        }
        Section {
            Button(together.paused ? "Play" : "Pause") { together.command("playpause") }
            Button("Back 30 seconds") { together.command("back30") }
            Button("Forward 30 seconds") { together.command("fwd30") }
            if together.isBook && !book.chapters.isEmpty {
                Button("Previous chapter") { together.command("prev") }
                Button("Next chapter") { together.command("next") }
                NavigationLink("Chapters") { ChapterList(bookID: book.bookID, bookTitle: book.title) }
            }
            if together.isBook && book.ready {
                Button("Add a bookmark here") { model.addBookmark(bookID: book.bookID, at: book.currentTime()) }
                NavigationLink("Bookmarks") { BookmarkList(bookID: book.bookID, bookTitle: book.title) }
            }
            if together.hasNextEpisode {
                Button("Next episode") { together.command("next") }
            }
            // asked first: it stops the others too
            Button("Stop for everyone") { askStop = true }
                .confirmationDialog("Stop for everyone?", isPresented: $askStop, titleVisibility: .visible) {
                    Button("Stop for everyone", role: .destructive) { together.stopAll() }
                    Button("Leave") { together.leave(quiet: false) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Leave stops it on this phone only. The others carry on.")
                }
            Button("Leave - the others carry on") { together.leave(quiet: false) }
        }
        if together.isBook {
            Section {
                Picker("Speed", selection: Binding(get: { together.room?.rate ?? 1 }, set: { together.setSpeed($0) })) {
                    ForEach(BookPlayer.speeds, id: \.self) { v in
                        Text(BookPlayer.speedLabel(v)).tag(v)
                    }
                }
            } header: {
                Heading("Listening")
            }
        }
    }
}

/// What happened while playing together, newest first.
struct TogetherEvents: View {
    @ObservedObject var together: Together
    var body: some View {
        List {
            ForEach(Array((together.room?.events ?? []).reversed().enumerated()), id: \.offset) { _, e in
                Text(e.text + " (" + TogetherEvents.ago(e.ago ?? 0) + ")")
            }
        }
        .navigationTitle("What happened")
    }
    static func ago(_ s: Int) -> String { s < 45 ? "just now" : s < 3600 ? "\(s / 60) min ago" : "\(s / 3600) h ago" }
}

/// Who to invite: only people who can sign in to the player.
struct InvitePicker: View {
    @ObservedObject var together: Together
    @State private var picked = Set<String>()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(together.inviting ?? []) { p in
                        Button {
                            if picked.contains(p.name) { picked.remove(p.name) } else { picked.insert(p.name) }
                        } label: {
                            HStack {
                                Image(systemName: picked.contains(p.name) ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(p.name).bold()
                                    Text((p.online == true ? "Using the app now" : "Not using the app right now") +
                                         (p.notify == true ? " - gets a phone notification" : "")).font(.footnote)
                                }
                            }
                        }
                        .accessibilityAddTraits(picked.contains(p.name) ? .isSelected : [])
                    }
                } footer: {
                    Text("They see an invitation in AD Player (and a phone notification when one is set up). Only people who can sign in to the player are listed.")
                }
            }
            .navigationTitle("Invite people")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now") { together.inviting = nil } }
                ToolbarItem(placement: .confirmationAction) { Button("Invite") { together.inviteSend(Array(picked)) }.disabled(picked.isEmpty) }
            }
        }
    }
}

// MARK: - Audiobooks

struct BookRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var offline = Offline.shared
    let item: BookItem
    @State private var showChapters = false

    private var canStartOver: Bool { item.canResume || item.finished == true }
    private var hasChapters: Bool { (item.chapters ?? 0) > 1 }

    /// What VoiceOver reads for the row: the book, and whether it's on the phone.
    private var rowLabel: String {
        guard let s = offline.find(item.id, "book") else { return item.spoken }
        switch s.state {
        case "done": return item.spoken + ", downloaded"
        case "failed": return item.spoken + ", didn't download"
        default: return item.spoken + ", downloading"
        }
    }

    var body: some View {
        switch item.type {
        case "BookSeries":
            NavigationLink(item.spoken) {
                BookListView(kind: "books_inseries", parent: item.id, title: item.label)
            }
        case "BookAuthor":
            NavigationLink(item.spoken) {
                BookListView(kind: "books_byauthor", parent: item.id, title: item.label)
            }
        case "Chapter":
            Button(item.spoken) {
                model.playBook(id: item.book ?? "", label: item.bookTitle ?? "", resume: false, at: item.start ?? 0)
            }
        default:
            // one VoiceOver stop: the row plays it; the buttons under it are actions (swipe up or down)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.playBook(id: item.id, label: item.label, resume: true)
                } label: {
                    Text(item.spoken)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(rowLabel)
                .accessibilityHint(item.canResume ? "Plays from where you left off." : "Plays it.")
                .voiceOverAction("Play together") { playTogether() }
                .voiceOverAction("Start over", if: canStartOver) { startOver() }
                .voiceOverAction("Chapters", if: hasChapters) { showChapters = true }
                .voiceOverAction(DownloadButton.text(offline, offline.find(item.id, "book"))) { download() }
                ButtonRow {
                    Button("Play together") { playTogether() }
                        .buttonStyle(.bordered)
                    if canStartOver {
                        Button("Start over") { startOver() }
                            .buttonStyle(.bordered)
                    }
                    if hasChapters {
                        Button("Chapters") { showChapters = true }
                            .buttonStyle(.bordered)
                    }
                    DownloadButton(offline: offline, id: item.id, kind: "book", label: item.label) { download() }
                }
                .accessibilityHidden(true)
            }
            .sheet(isPresented: $showChapters) {
                NavigationStack {
                    ChapterList(bookID: item.id, bookTitle: item.label)
                        .accessibilityAction(.escape) { showChapters = false }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showChapters = false }
                            }
                        }
                }
                .environmentObject(model)
            }
        }
    }

    private func playTogether() { model.playBook(id: item.id, label: item.label, resume: true, together: true) }
    private func startOver() { model.playBook(id: item.id, label: item.label, resume: false, at: 0) }
    private func download() {
        DownloadButton.press(offline, id: item.id, kind: "book", label: item.label) {
            offline.downloadBook(id: item.id, label: item.label)
        }
    }
}

struct BookListView: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let parent: String?
    let title: String
    @State private var items: [BookItem] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var loadedAt: Date?

    var body: some View {
        List {
            if loading && items.isEmpty {
                Text("Loading…")
            } else if let problem = problem {
                Text(problem)
            } else if items.isEmpty {
                Text("Nothing here.")
            }
            ForEach(items) { item in
                BookRow(item: item)
            }
        }
        .navigationTitle(title)
        .homeBar()
        // once when it opens; back from a deeper list it's only fetched again after 5 minutes (or pull to refresh)
        .task { if loadedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        do {
            items = try await model.bookList(kind: kind, parent: parent)
            problem = nil
            loadedAt = Date()
        } catch {
            if !Task.isCancelled { problem = error.localizedDescription }
            loadedAt = nil
        }
        loading = false
    }
}

/// A book's chapters; choosing one plays the book from there and goes back.
/// Her bookmarks in a book: each one plays from there; Rename and Remove are VoiceOver actions (swipe up or down),
/// or a swipe left on the row.
struct BookmarkList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bookID: String
    let bookTitle: String
    @State private var items: [BookmarkEntry] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var renaming: BookmarkEntry?
    @State private var newName = ""

    var body: some View {
        List {
            if loading && items.isEmpty {
                Text("Loading…")
            } else if let problem = problem {
                Text(problem)
            } else if items.isEmpty {
                Text("No bookmarks in this book yet. While it plays, Add a bookmark here keeps the place.")
            }
            ForEach(items) { b in
                Button(b.spoken) {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        model.playBook(id: bookID, label: bookTitle, resume: false, at: b.time)
                    }
                }
                .accessibilityAction(named: "Rename") { newName = b.title; renaming = b }
                .accessibilityAction(named: "Remove") { remove(b) }
                .swipeActions {
                    Button("Remove", role: .destructive) { remove(b) }
                    Button("Rename") { newName = b.title; renaming = b }
                }
            }
        }
        .navigationTitle(bookTitle.isEmpty ? "Bookmarks" : "\(bookTitle) bookmarks")
        .task { await load() }
        .alert("Rename the bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let b = renaming { change(b, "rename", newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func remove(_ b: BookmarkEntry) { change(b, "remove", "") }

    private func change(_ b: BookmarkEntry, _ action: String, _ title: String) {
        Task {
            do { items = try await model.changeBookmark(bookID, action, time: b.time, title: title) }
            catch { model.say(error.localizedDescription) }
        }
    }

    private func load() async {
        loading = true
        do {
            items = try await model.bookmarks(bookID)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }
}

struct ChapterList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bookID: String
    let bookTitle: String
    @State private var items: [BookItem] = []
    @State private var loading = true
    @State private var problem: String?

    var body: some View {
        List {
            if loading && items.isEmpty {
                Text("Loading…")
            } else if let problem = problem {
                Text(problem)
            } else if items.isEmpty {
                Text("This book has no chapters.")
            }
            ForEach(items) { item in
                Button(item.spoken) {
                    let label = item.bookTitle ?? bookTitle
                    let at = item.start ?? 0
                    dismiss()
                    // after the list has closed, so the player screen can open
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        model.playBook(id: bookID, label: label, resume: false, at: at)
                    }
                }
            }
        }
        .navigationTitle(bookTitle.isEmpty ? "Chapters" : "\(bookTitle) chapters")
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            items = try await model.bookList(kind: "books_chapters", parent: bookID)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }
}

struct BookSearchView: View {
    @EnvironmentObject var model: AppModel
    var initial = ""
    @State private var text = ""
    @State private var items: [BookItem] = []
    @State private var note = "Type a title, author, narrator or series, then press Search."
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                TextField("Search audiobooks", text: $text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { run() }
                Button("Search") { run() }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(note)
            }
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        BookRow(item: item)
                    }
                } header: {
                    Heading("Found")
                }
            }
        }
        .navigationTitle("Search audiobooks")
        .homeBar()
        .onAppear { if !initial.isEmpty && text.isEmpty { text = initial; run() } else if initial.isEmpty { focused = true } }
    }

    private func run() {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        focused = false
        note = "Searching…"
        Task {
            do {
                items = try await model.bookList(kind: "books_search", query: q)
                note = items.isEmpty ? "Nothing found for \(q)." : "\(items.count) found."
            } catch {
                items = []
                note = error.localizedDescription
            }
            model.announce(note)
        }
    }
}
