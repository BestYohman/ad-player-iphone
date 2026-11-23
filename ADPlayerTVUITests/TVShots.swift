import XCTest

/// GitHub only: drives the Apple TV app with the Siri Remote's buttons against the stand-in PC (.github/screens/mock.py)
/// and saves a screenshot after each step (they go to the tv-screens branch).
final class TVShots: XCTestCase {
    private let dir = "/tmp/tvshots"

    private func shot(_ name: String, wait: Double = 2) {
        Thread.sleep(forTimeInterval: wait)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func press(_ b: XCUIRemote.Button, _ times: Int = 1) {
        for _ in 0..<times {
            XCUIRemote.shared.press(b)
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    func testScreens() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-server", "http://127.0.0.1:8080", "-uitestToken", "tok"]
        app.launch()
        shot("01_sight", wait: 10)
        press(.select)                          // Full vision (the first one)
        shot("02_home", wait: 8)
        press(.down)
        shot("03_home_focus")
        press(.select)                          // More info on the big picture
        shot("04_detail", wait: 6)
        press(.select)                          // Resume / Play
        shot("05_player", wait: 8)
        press(.playPause)
        shot("06_player_paused", wait: 2)
        press(.down)
        shot("07_player_down", wait: 2)
        press(.menu)
        shot("08_player_menu1", wait: 2)
        press(.menu)
        shot("09_after_player", wait: 3)
        press(.menu)
        shot("10_back_home", wait: 3)
        press(.up, 3)                           // the tabs at the top
        press(.right)
        shot("11_shows", wait: 6)
        press(.down)
        shot("12_shows_focus")
        press(.select)
        shot("13_series", wait: 6)
        press(.down, 3)
        shot("14_series_seasons", wait: 2)
        press(.down)
        shot("15_series_episodes", wait: 3)
        press(.menu)
        press(.menu)
        press(.up, 3)
        press(.right, 3)                        // You
        shot("16_you", wait: 4)
    }
}
