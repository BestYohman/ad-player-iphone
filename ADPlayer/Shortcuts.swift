import AppIntents

// Siri and the Shortcuts app (they work with a free Apple ID: nothing special is needed to sign the app).
// "Play in AD Player" - Siri asks what to play. "Resume AD Player". "Where am I in AD Player".

/// Finds a movie, show, episode or audiobook on the PC and plays the best match (a show: its next episode).
struct PlayTitleIntent: AppIntent {
    static var title: LocalizedStringResource = "Play in AD Player"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Title", requestValueDialog: "What should AD Player play?")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await AppModel.shared.playBestMatch(name)
        return .result(dialog: "\(said)")
    }
}

/// Carries on with what's loaded, or the last thing played on this phone, from her place.
struct ResumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume AD Player"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = AppModel.shared.resumeForSiri()
        return .result(dialog: "\(said)")
    }
}

/// Says what's playing, where it is and the time left.
struct WhereAmIIntent: AppIntent {
    static var title: LocalizedStringResource = "Where am I in AD Player"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await AppModel.shared.whereAmIText()
        return .result(dialog: "\(said)")
    }
}

struct ADPlayerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayTitleIntent(),
                    phrases: ["Play in \(.applicationName)", "Play something in \(.applicationName)"],
                    shortTitle: "Play", systemImageName: "play.fill")
        AppShortcut(intent: ResumeIntent(),
                    phrases: ["Resume \(.applicationName)", "Carry on in \(.applicationName)"],
                    shortTitle: "Resume", systemImageName: "playpause.fill")
        AppShortcut(intent: WhereAmIIntent(),
                    phrases: ["Where am I in \(.applicationName)"],
                    shortTitle: "Where am I", systemImageName: "clock")
    }
}
