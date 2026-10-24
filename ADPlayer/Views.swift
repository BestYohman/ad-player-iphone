import SwiftUI

// Plain lists and buttons only - the standard iPhone controls, which VoiceOver reads best.

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if model.api == nil {
                SetupView(first: true)
            } else {
                HomeView()
            }
        }
        .onChange(of: phase) { newPhase in
            model.scene(active: newPhase == .active)
        }
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
                    Text("The same address as the AD Player web page: the PC's address and port 5021. The first time, iPhone asks to find devices on your local network - choose Allow.")
                }
                Section {
                    Button(busy ? "Connecting…" : "Connect") { connect() }
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !note.isEmpty {
                    Section { Text(note) }
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

// MARK: - Home: where to play, carry on, find something

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
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
                } footer: {
                    if !model.otherDevices.isEmpty {
                        Text("Connected but can't be controlled from here: \(model.otherDevices.joined(separator: ", ")). Use the Emby app on that TV instead.")
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
                Section {
                    Button("Where am I?") { model.whereAmI() }
                    Button("Find something else") { model.showPlayer = false }
                }
            }
            .navigationTitle("Now playing")
            .navigationBarTitleDisplayMode(.inline)
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
