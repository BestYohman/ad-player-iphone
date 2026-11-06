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
            } else {
                HomeView()
            }
        }
        .onChange(of: phase) { newPhase in
            model.scene(active: newPhase == .active)
        }
        // adplayer://join - from a "play together" notification: show the Join button straight away
        .onOpenURL { _ in Task { await model.together.pollInvites() } }
        .onAppear { model.scene(active: true) }
    }
}

// MARK: - Address of the PC

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let first: Bool
    @State private var text = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        NavigationStack {
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
                if !first {
                    Section {
                        Picker("Headphone delay when playing together", selection: Binding(get: { model.together.delayChoice },
                                                                                        set: { model.together.delayChoice = $0 })) {
                            ForEach(Together.delays, id: \.0) { d in
                                Text(d.1).tag(d.0)
                            }
                        }
                    } footer: {
                        Text("Auto asks iPhone how late the headphones are (AirPods are about 0.2 seconds), so both of you hear it at the same moment.")
                    }
                    Section {
                        Text(model.atHome ? "Connected at home, straight to the PC." : "Connected through the address above.")
                        if let name = model.me?.name, !name.isEmpty, !model.needSignIn {
                            Text("Signed in as \(name).")
                            Button("Sign out") { model.signOut(); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(first ? "Set up AD Player" : "Settings")
            .toolbar {
                if !first {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear { if text.isEmpty { text = model.server } }
        }
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
                if !first { dismiss() }
            }
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

    private var kinds: [(String, String)] {
        (model.booksSetUp ? [("books", "Audiobooks")] : []) + [("shows", "Shows"), ("movies", "Movies")]
    }
    private var shown: String { model.booksSetUp || what != "books" ? what : "shows" }
    private var movies: Bool { shown == "movies" }

    var body: some View {
        NavigationStack {
            List {
                InvitesSection(together: model.together)
                NowPlayingRow(phone: model.phone, book: model.book)

                Section {
                    Picker("Play on", selection: $model.target) {
                        Text(AppModel.phoneName).tag(AppModel.phoneID)
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
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
                    Text("TV")
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
                        Text("Audiobooks")
                    } footer: {
                        Text("A title, author, narrator or series.")
                    }
                    Section("Continue listening") {
                        if model.continueBooks.isEmpty {
                            Text(model.booksNote.isEmpty ? "Nothing in progress." : model.booksNote)
                        }
                        ForEach(model.continueBooks) { item in BookRow(item: item) }
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
                        Text(movies ? "Movies" : "Shows")
                    } footer: {
                        if !movies { Text("For one episode, type the show, season and episode, like: friends 4 2") }
                    }
                    Section(movies ? "Movies in progress" : "Shows in progress") {
                        if progress.isEmpty {
                            Text(progressLoading ? "Loading…" : "Nothing in progress.")
                        }
                        ForEach(progress) { item in ItemRow(item: item) }
                    }
                }

                Section {
                    NavigationLink { DownloadsView() } label: { DownloadsLabel(offline: Offline.shared) }
                } footer: {
                    Text("Episodes, movies and audiobooks kept on this phone, to play with no connection.")
                }

                if !model.message.isEmpty {
                    Section("Last message") {
                        Text(model.message)
                    }
                }

                Section("You") {
                    if let name = model.me?.name, !name.isEmpty {
                        Text("Signed in as \(name).")
                    }
                    Button("Settings") { showSettings = true }
                    if let name = model.me?.name, !name.isEmpty, !model.needSignIn {
                        Button("Sign out") { model.signOut() }
                    }
                }
            }
            .navigationTitle("AD Player")
            .navigationDestination(isPresented: Binding(get: { searchFor != nil }, set: { if !$0 { searchFor = nil } })) {
                if let q = searchFor {
                    if shown == "books" { BookSearchView(initial: q) } else { SearchView(kind: "search_\(shown)", initial: q) }
                }
            }
            .task(id: shown) { await loadProgress() }
            .onChange(of: model.continueItems) { _ in Task { await loadProgress() } }   // after Stop, a TV finishing…
            .refreshable { await model.refreshAll(); await loadProgress() }
            .sheet(isPresented: $showSettings) {
                SetupView(first: false).environmentObject(model)
            }
            .fullScreenCover(isPresented: $model.showPlayer) {
                NowPlayingView(phone: model.phone, book: model.book).environmentObject(model)
            }
        }
        .id(model.homeToken)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { model.announce("Type something to search for."); return }
        searchFor = q
    }

    private func loadProgress() async {
        guard shown != "books" else { return }
        progressLoading = true
        defer { progressLoading = false }
        if let items = try? await model.list(kind: "continue_\(shown)") { progress = items }
    }
}

/// "Bob wants to play … together" with a Join button, at the top of Home.
struct InvitesSection: View {
    @ObservedObject var together: Together

    var body: some View {
        if !together.active && !together.invites.isEmpty {
            Section("Play together") {
                ForEach(together.invites) { inv in
                    Button("Join \(inv.by): \(inv.title)") { together.join(inv) }
                        .accessibilityHint("\(inv.by) wants to \(inv.kind == "book" ? "listen to" : "play") it together.")
                }
            }
        }
    }
}

/// "Now playing: …" at the top of Home, to get back to the controls.
struct NowPlayingRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var phone: PhonePlayer
    @ObservedObject var book: BookPlayer

    var body: some View {
        if let title = nowTitle {
            Section {
                Button("Now playing: \(title)") { model.showPlayer = true }
            }
        }
    }

    private var nowTitle: String? {
        if model.together.active { return model.together.room?.title ?? "playing together" }
        if model.isPhone {
            if book.active { return book.title }
            return phone.active ? phone.title : nil
        }
        if let s = model.tvStatus, s.playing { return s.title ?? s.text }
        return nil
    }
}

// MARK: - Lists

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: Item
    @State private var favorite: Bool?
    @State private var requested: Bool?

    var body: some View {
        switch item.type ?? "" {
        case "Request":
            Text("\(item.label): \(item.text ?? ""). Asked for on \(item.date ?? "").")
        case "Series":
            VStack(alignment: .leading, spacing: 6) {
                NavigationLink(item.spoken) {
                    ItemListView(kind: "seasons", parent: item.id, title: "\(item.label) seasons")
                }
                actions
            }
        case "Season":
            NavigationLink(item.spoken) {
                ItemListView(kind: "episodes", parent: item.id, title: item.label)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.play(item, resume: true)
                } label: {
                    Text(item.spoken)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .accessibilityHint(item.canResume ? "Plays from where you left off." : "Plays it.")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("Play together") { model.play(item, resume: true, together: true) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Play \(item.label) together")
                            .accessibilityHint("It also plays on another person's phone, in step. They get a Join button.")
                        if item.canResume {
                            Button("Start over") { model.play(item, resume: false) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Start \(item.label) from the beginning")
                        }
                        if item.type == "Episode" || item.type == "Movie" || item.type == "Video" {
                            DownloadButton(offline: Offline.shared, id: item.id, kind: "audio", label: item.label) {
                                Offline.shared.download(item)
                            }
                        }
                        actions
                    }
                }
            }
        }
    }

    /// Add to favorites (shows and movies) and Ask for audio description (ones without it), as on the web page.
    @ViewBuilder private var actions: some View {
        let fav = favorite ?? (item.favorite ?? false)
        let asked = requested ?? (item.requested ?? false)
        HStack {
            if item.type == "Series" || item.type == "Movie" {
                Button(fav ? "Remove from favorites" : "Add to favorites") {
                    Task {
                        if let m = await model.setFavorite(item, on: !fav) { favorite = !fav; model.announce(m) }
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(fav ? "Remove \(item.label) from favorites" : "Add \(item.label) to favorites")
            }
            if item.hasAD == false {
                Button(asked ? "Asked for audio description" : "Ask for audio description") {
                    Task {
                        if let m = await model.requestAD(item) { requested = true; model.announce(m) }
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel((asked ? "Asked for audio description for " : "Ask for audio description for ") + item.label)
            }
        }
    }
}

struct ItemListView: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let parent: String?
    let title: String
    var empty = "Nothing here."
    @State private var items: [Item] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var view = ListView()
    @State private var viewLoaded = false
    @State private var showSort = false

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
        .task {
            if !viewLoaded { view = ListView.load(kind); viewLoaded = true }
            await load()
        }
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
            if announce {
                model.announce(items.isEmpty ? (view.filtersOn > 0 ? "Nothing matches these filters." : "Nothing here.")
                                             : "\(items.count) item\(items.count == 1 ? "" : "s").")
            }
        } catch {
            problem = error.localizedDescription
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
        content.toolbar {
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
                Section("Found") {
                    ForEach(items) { item in
                        ItemRow(item: item)
                    }
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

    var body: some View {
        let s = offline.find(id, kind)
        let text: String = {
            guard let s = s else { return "Download" }
            switch s.state {
            case "done": return "Downloaded"
            case "failed": return "Download again"
            case "preparing": return "Getting ready" + (s.progress > 0 ? " \(s.progress)%" : "")
            default: return "Downloading" + (s.progress > 0 ? " \(s.progress)%" : "")
            }
        }()
        Button(text) {
            if let s = s, s.state != "failed" { offline.say("\(label): \(s.stateText).") } else { start() }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(s == nil ? "Download \(label)" : "\(label): \(s!.stateText)")
        .accessibilityHint(s == nil ? "Keeps it on this phone, to play with no connection." : "")
    }
}

struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var offline = Offline.shared

    var body: some View {
        List {
            if offline.items.isEmpty {
                Text("Nothing downloaded yet. Use Download beside an episode, a movie or an audiobook.")
            }
            ForEach(Array(offline.items.reversed())) { s in
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
                    HStack {
                        if s.state == "failed" {
                            Button("Try again") { offline.retry(s) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Try downloading \(s.title) again")
                        }
                        Button(s.done ? "Remove" : "Stop", role: .destructive) { offline.remove(s) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel((s.done ? "Remove the download of " : "Stop downloading ") + s.title)
                    }
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
    }
}

// MARK: - Now playing: only the controls

struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var phone: PhonePlayer
    @ObservedObject var book: BookPlayer

    var body: some View {
        NavigationStack {
            List {
                if model.together.active {
                    TogetherControls(together: model.together, book: book)
                } else {
                    soloControls
                }
                Section {
                    Button("Where am I?") { model.whereAmI() }
                    Button("Find something else") { model.showPlayer = false }
                }
            }
            .navigationTitle("Now playing")
            .navigationBarTitleDisplayMode(.inline)
            .homeBar()
        }
    }

    @ViewBuilder private var soloControls: some View {
                Section {
                    Text(statusText)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if model.isPhone && book.active {
                    bookControls
                } else if model.isPhone {
                    phoneControls
                } else if model.tvStatus?.book == true {
                    tvBookControls
                } else {
                    tvControls
                }
    }

    private var statusText: String {
        if model.isPhone { return book.active ? book.statusText : phone.statusText }
        return model.tvStatus?.text ?? "Checking the TV…"
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
        let s = model.tvStatus
        Section {
            Button(s?.paused == true ? "Play" : "Pause") { model.tv(s?.paused == true ? "unpause" : "pause") }
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
        Section("TV volume") {
            Button("Volume down") { model.tv("voldown") }
            Button("Volume up") { model.tv("volup") }
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
        Section("Listening") {
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
        }
    }

    @ViewBuilder private var tvBookControls: some View {
        let s = model.tvStatus
        Section {
            Button(s?.paused == true ? "Play" : "Pause") { model.tv(s?.paused == true ? "unpause" : "pause") }
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
        Section("Listening") {
            Picker("Sleep timer", selection: Binding(get: { s?.sleepVal ?? "off" }, set: { model.tv("sleep:" + $0) })) {
                ForEach(BookPlayer.sleepChoices, id: \.value) { c in
                    Text(c.label).tag(c.value)
                }
            }
        }
        Section("TV volume") {
            Button("Volume down") { model.tv("voldown") }
            Button("Volume up") { model.tv("volup") }
        }
    }
}

/// The buttons while playing together: they work the shared clock, so both phones follow.
struct TogetherControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var together: Together
    @ObservedObject var book: BookPlayer

    var body: some View {
        Section {
            Text(together.statusText)
                .accessibilityAddTraits(.updatesFrequently)
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
            Button("Stop for everyone") { together.stopAll() }
            Button("Leave - the others carry on") { together.leave(quiet: false) }
        }
        if together.isBook {
            Section("Listening") {
                Picker("Speed", selection: Binding(get: { together.room?.rate ?? 1 }, set: { together.setSpeed($0) })) {
                    ForEach(BookPlayer.speeds, id: \.self) { v in
                        Text(BookPlayer.speedLabel(v)).tag(v)
                    }
                }
            }
        }
    }
}

// MARK: - Audiobooks

struct BookRow: View {
    @EnvironmentObject var model: AppModel
    let item: BookItem
    @State private var showChapters = false

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
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.playBook(id: item.id, label: item.label, resume: true)
                } label: {
                    Text(item.spoken)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .accessibilityHint(item.canResume ? "Plays from where you left off." : "Plays it.")
                Group {
                    HStack {
                        Button("Play together") { model.playBook(id: item.id, label: item.label, resume: true, together: true) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Play \(item.label) together")
                            .accessibilityHint("It also plays on another person's phone, in step. They get a Join button.")
                        if item.canResume || item.finished == true {
                            Button("Start over") { model.playBook(id: item.id, label: item.label, resume: false, at: 0) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Start \(item.label) from the beginning")
                        }
                        if (item.chapters ?? 0) > 1 {
                            Button("Chapters") { showChapters = true }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Chapters of \(item.label)")
                        }
                        DownloadButton(offline: Offline.shared, id: item.id, kind: "book", label: item.label) {
                            Offline.shared.downloadBook(id: item.id, label: item.label)
                        }
                    }
                }
            }
            .sheet(isPresented: $showChapters) {
                NavigationStack {
                    ChapterList(bookID: item.id, bookTitle: item.label)
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
}

struct BookListView: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let parent: String?
    let title: String
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
                Text("Nothing here.")
            }
            ForEach(items) { item in
                BookRow(item: item)
            }
        }
        .navigationTitle(title)
        .homeBar()
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        do {
            items = try await model.bookList(kind: kind, parent: parent)
            problem = nil
        } catch {
            problem = error.localizedDescription
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
                Section("Found") {
                    ForEach(items) { item in
                        BookRow(item: item)
                    }
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
