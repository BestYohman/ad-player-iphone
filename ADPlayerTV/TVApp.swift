import SwiftUI

/// The Apple TV app: the same PC, sign-in and video as the iPhone app (the shared files in ADPlayer/),
/// with screens made for the Siri Remote.
@main
struct ADPlayerTVApp: App {
    @StateObject private var model = AppModel.shared

    init() {
        #if DEBUG
        // GitHub's screenshot test only (debug builds): signed in to the stand-in PC without typing
        if let t = UserDefaults.standard.string(forKey: "uitestToken"), !t.isEmpty { API.token = t }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TVRoot().environmentObject(model)
        }
    }
}

/// Bigger text for low vision (the TV's sizes are already large).
struct TVSize {
    let k: CGFloat
    @MainActor init(_ m: AppModel) {
        guard m.low else { k = 1; return }
        switch m.opts.size ?? "large" {
        case "normal": k = 1.1
        case "larger": k = 1.4
        case "largest": k = 1.6
        default: k = 1.25
        }
    }
    func f(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * k, weight: w) }
}

struct TVRoot: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let look = Look.of(model)
        Group {
            if model.api == nil {
                TVSetup(first: true)
            } else if model.needSignIn {
                TVSignIn()
            } else if !model.sightChosen {
                TVSightPage(first: true)
            } else {
                TVMain(video: model.video)
            }
        }
        .preferredColorScheme(look.bg == .white ? .light : .dark)
        .overlay(alignment: .bottom) { TVToast() }
        .onChange(of: phase) { p in model.scene(active: p == .active) }
        .onAppear { model.scene(active: true) }
    }
}

/// What the app just said ("Starting …", a problem): shown for a few seconds at the bottom (VoiceOver reads it too).
struct TVToast: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        if !model.message.isEmpty && !model.video.shown {
            Text(model.message)
                .font(sz.f(30, .semibold))
                .padding(.horizontal, 36).padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 22).fill(look.card))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(look.line, lineWidth: look.lineWidth))
                .foregroundStyle(look.fg)
                .padding(.bottom, 50)
                .accessibilityHidden(true)
                .task(id: model.message) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !Task.isCancelled { model.message = "" }
                }
        }
    }
}

// MARK: - The PC's address and signing in

struct TVSetup: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let first: Bool
    @State private var text = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text("AD Player").font(.system(size: 76, weight: .heavy)).accessibilityAddTraits(.isHeader)
            Text("Type the address of the PC that runs AD Player - the same one the iPhone or Android app uses.")
                .font(.system(size: 34)).foregroundStyle(.secondary).frame(maxWidth: 1300, alignment: .leading)
            TextField("For example 192.168.1.20:5021", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 900)
                .onSubmit { connect() }
            HStack(spacing: 30) {
                Button(busy ? "Connecting…" : "Connect") { connect() }.disabled(busy)
                if !first { Button("Cancel") { dismiss() } }
            }
            if !note.isEmpty { Text(note).font(.system(size: 30)).frame(maxWidth: 1300, alignment: .leading) }
        }
        .padding(90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                if !first { dismiss() }
            }
        }
    }
}

struct TVSignIn: View {
    @EnvironmentObject var model: AppModel
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var note = ""
    @State private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Sign in").font(.system(size: 76, weight: .heavy)).accessibilityAddTraits(.isHeader)
            Text("Your Emby user name and password. The Apple TV stays signed in.").font(.system(size: 34)).foregroundStyle(.secondary)
            TextField("User name", text: $user)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 900)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .frame(maxWidth: 900)
                .onSubmit { go() }
            HStack(spacing: 30) {
                Button(busy ? "Signing in…" : "Sign in") { go() }
                    .disabled(busy || user.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Change the address of the PC") { showSetup = true }
            }
            if !note.isEmpty { Text(note).font(.system(size: 30)) }
        }
        .padding(90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fullScreenCover(isPresented: $showSetup) { TVSetup(first: false).environmentObject(model) }
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

// MARK: - How you see the screen (full or low vision; the audio-only layout is the phone's)

struct TVSightPage: View {
    @EnvironmentObject var model: AppModel
    let first: Bool

    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("How do you see the screen?").font(sz.f(60, .heavy)).accessibilityAddTraits(.isHeader)
                if first {
                    Text("Pick the one that fits you. You can change it any time under You.").font(sz.f(32)).foregroundStyle(look.sub)
                }
                ForEach(Array(SIGHTS.filter { $0.0 != "none" }.reversed()), id: \.0) { s in
                    let on = model.sight == s.0 || (s.0 == "full" && model.sight == "none")
                    Button {
                        model.sightSave(["sight": s.0], said: sightSaid(s.0))
                    } label: {
                        HStack(alignment: .top, spacing: 24) {
                            Image(systemName: on && !first ? "largecircle.fill.circle" : "circle").font(sz.f(40))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(s.1).font(sz.f(38, .bold))
                                Text(s.2).font(sz.f(30))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(26)
                        .frame(maxWidth: 1200, alignment: .leading)
                    }
                    .accessibilityAddTraits(on && !first ? .isSelected : [])
                }
                if !first && model.low { TVLowOptions() }
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
    }
}

/// Low vision's choices: text size, colours, posters (each press moves to the next choice).
struct TVLowOptions: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let sz = TVSize(model)
        let sizes = [("normal", "Normal"), ("large", "Large"), ("larger", "Larger"), ("largest", "Largest")]
        let screens = [("dark", "Dark"), ("light", "Light"), ("yellow", "Yellow on black")]
        let size = model.opts.size ?? "large"
        let screen = model.opts.screen ?? "dark"
        VStack(alignment: .leading, spacing: 20) {
            Button {
                let i = (sizes.firstIndex { $0.0 == size } ?? 1) + 1
                let n = sizes[i % sizes.count]
                model.sightSave(["size": n.0], said: "Text size: \(n.1).")
            } label: { Text("Text size: \(sizes.first { $0.0 == size }?.1 ?? "Large")").font(sz.f(32, .semibold)) }
            Button {
                let i = (screens.firstIndex { $0.0 == screen } ?? 0) + 1
                let n = screens[i % screens.count]
                model.sightSave(["screen": n.0], said: "Screen: \(n.1).")
            } label: { Text("Screen: \(screens.first { $0.0 == screen }?.1 ?? "Dark")").font(sz.f(32, .semibold)) }
            Button {
                let on = model.opts.posters != false
                model.sightSave(["posters": on ? "0" : "1"], said: "Posters: \(on ? "off" : "on").")
            } label: { Text("Posters and pictures: \(model.opts.posters != false ? "on" : "off")").font(sz.f(32, .semibold)) }
        }
    }
}

// MARK: - The tabs

struct TVMain: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var video: VideoModel
    @State private var tab = "home"

    var body: some View {
        let look = Look.of(model)
        TabView(selection: $tab) {
            NavigationStack { TVHome() }.tabItem { Text("Home") }.tag("home")
            NavigationStack { TVGrid(kind: "shows", title: "TV shows") }.tabItem { Text("Shows") }.tag("shows")
            NavigationStack { TVGrid(kind: "movies", title: "Movies") }.tabItem { Text("Movies") }.tag("movies")
            NavigationStack { TVSearch() }.tabItem { Image(systemName: "magnifyingglass").accessibilityLabel("Search") }.tag("search")
            NavigationStack { TVYou() }.tabItem { Text("You") }.tag("you")
        }
        .tint(look.accent)
        .fullScreenCover(isPresented: $video.shown) {
            TVPlayer(video: video).environmentObject(model)
        }
        // the Menu button closes the player: the video stops there (its place is kept on the PC)
        .onChange(of: video.shown) { shown in if !shown && video.active { video.stop() } }
    }
}

struct TVYou: View {
    @EnvironmentObject var model: AppModel
    @State private var showSetup = false

    var body: some View {
        let look = Look.of(model)
        let sz = TVSize(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("You").font(sz.f(60, .heavy)).accessibilityAddTraits(.isHeader)
                Text("Signed in as \(model.me?.name ?? "")").font(sz.f(32))
                Text(model.atHome ? "Connected at home, straight to the PC." : "Connected through \(model.server).").font(sz.f(28)).foregroundStyle(look.sub)
                HStack(spacing: 30) {
                    Button("Sign out") { model.signOut() }
                    Button("Change the address of the PC") { showSetup = true }
                }
                if model.sightKnown {
                    NavigationLink { TVSightPage(first: false) } label: {
                        Text("How you see the screen: \(model.sight == "low" ? "Low vision" : "Full vision")").font(sz.f(32, .semibold))
                    }
                }
                Text("AD Player for Apple TV \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(sz.f(24)).foregroundStyle(look.sub)
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(look.bg.ignoresSafeArea())
        .foregroundStyle(look.fg)
        .fullScreenCover(isPresented: $showSetup) { TVSetup(first: false).environmentObject(model) }
    }
}
