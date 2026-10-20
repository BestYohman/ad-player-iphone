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

                NowPlayingRow(phone: model.phone)

                Section("Continue watching") {
                    if model.continueItems.isEmpty {
                        Text(model.continueLoading ? "Loading…" : "Nothing in progress.")
                    }
                    ForEach(model.continueItems) { item in
                        ItemRow(item: item)
                    }
                }

                Section("Find something") {
                    NavigationLink("Shows") { ItemListView(kind: "shows", parent: nil, title: "Shows") }
                    NavigationLink("Movies") { ItemListView(kind: "movies", parent: nil, title: "Movies") }
                    NavigationLink("Search") { SearchView() }
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
                NowPlayingView(phone: model.phone).environmentObject(model)
            }
        }
    }
}

/// "Now playing: …" at the top of Home, to get back to the controls.
struct NowPlayingRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var phone: PhonePlayer

    var body: some View {
        if let title = nowTitle {
            Section {
                Button("Now playing: \(title)") { model.showPlayer = true }
            }
        }
    }

    private var nowTitle: String? {
        if model.isPhone { return phone.active ? phone.title : nil }
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(statusText)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if model.isPhone {
                    phoneControls
                } else {
                    tvControls
                }
                Section {
                    Button("Where am I?") { model.whereAmI() }
                    Button("Find something else to watch") { model.showPlayer = false }
                }
            }
            .navigationTitle("Now playing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusText: String {
        if model.isPhone { return phone.statusText }
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
}
