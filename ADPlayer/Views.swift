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

// MARK: - Home: where to play, carry on, find something

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                InvitesSection(together: model.together)

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
                    if model.isPhone {
                        Toggle("Play together", isOn: Binding(get: { model.together.enabled },
                                                              set: { model.together.enabled = $0
                                                                     model.announce($0 ? "Play together is on. What you start now also plays on the other person's phone once they join." : "Play together is off.") }))
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.isPhone {
                            Text("Play together: what you start here also plays on another person's phone, in step. They get a Join button.")
                        }
                        if !model.otherDevices.isEmpty {
                            Text("Connected but can't be controlled from here: \(model.otherDevices.joined(separator: ", ")). Use the Emby app on that TV instead.")
                        }
                    }
                }

                NowPlayingRow(phone: model.phone, book: model.book)

                Section("Continue watching") {
                    if model.continueItems.isEmpty {
                        Text(model.continueLoading ? "Loading…" : "Nothing in progress.")
                    }
                    ForEach(model.continueItems) { item in
                        ItemRow(item: item)
                    }
                }

                if model.booksSetUp {
                    Section("Continue listening") {
                        if model.continueBooks.isEmpty {
                            Text(model.booksNote.isEmpty ? "No audiobook in progress." : model.booksNote)
                        }
                        ForEach(model.continueBooks) { item in
                            BookRow(item: item)
                        }
                    }
                }

                Section("Find something") {
                    NavigationLink("Shows") { ItemListView(kind: "shows", parent: nil, title: "Shows") }
                    NavigationLink("Movies") { ItemListView(kind: "movies", parent: nil, title: "Movies") }
                    NavigationLink("Search") { SearchView() }
                }

                if model.booksSetUp {
                    Section("Audiobooks") {
                        NavigationLink("All books") { BookListView(kind: "books_all", parent: nil, title: "All audiobooks") }
                        NavigationLink("Series") { BookListView(kind: "books_series", parent: nil, title: "Audiobook series") }
                        NavigationLink("Authors") { BookListView(kind: "books_authors", parent: nil, title: "Audiobook authors") }
                        NavigationLink("Search audiobooks") { BookSearchView() }
                    }
                }

                if !model.message.isEmpty {
                    Section("Last message") {
                        Text(model.message)
                    }
                }
            }
            .navigationTitle("AD Player")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Settings") { showSettings = true }
                }
            }
            .refreshable { await model.refreshAll() }
            .sheet(isPresented: $showSettings) {
                SetupView(first: false).environmentObject(model)
            }
            .fullScreenCover(isPresented: $model.showPlayer) {
                NowPlayingView(phone: model.phone, book: model.book).environmentObject(model)
            }
        }
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

    var body: some View {
        switch item.type ?? "" {
        case "Series":
            NavigationLink(item.label) {
                ItemListView(kind: "seasons", parent: item.id, title: item.label)
            }
        case "Season":
            NavigationLink(item.spoken) {
                ItemListView(kind: "episodes", parent: item.id, title: item.label)
            }
        default:
            HStack {
                Button {
                    model.play(item, resume: true)
                } label: {
                    Text(item.spoken)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .accessibilityHint(item.canResume ? "Plays from where you left off." : "Plays it.")
                if item.canResume {
                    Button("Start over") { model.play(item, resume: false) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

struct ItemListView: View {
    @EnvironmentObject var model: AppModel
    let kind: String
    let parent: String?
    let title: String
    @State private var items: [Item] = []
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
                ItemRow(item: item)
            }
        }
        .navigationTitle(title)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        do {
            items = try await model.list(kind: kind, parent: parent)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }
}

struct SearchView: View {
    @EnvironmentObject var model: AppModel
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
        .onAppear { focused = true }
    }

    private func run() {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        focused = false
        note = "Searching…"
        Task {
            do {
                items = try await model.list(kind: "search", query: q)
                note = items.isEmpty ? "Nothing found for \(q)." : "\(items.count) found."
            } catch {
                items = []
                note = error.localizedDescription
            }
            model.announce(note)
        }
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
                if item.canResume || item.finished == true || (item.chapters ?? 0) > 1 {
                    HStack {
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
        .onAppear { focused = true }
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
