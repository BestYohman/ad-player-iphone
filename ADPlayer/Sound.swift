import Foundation
import AVFoundation

/// The phone's sound: set up for spoken audio, and let go when nothing plays (so other apps can carry on).
enum Sound {
    /// Returns what went wrong, if anything.
    @discardableResult
    static func activate() -> String? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            return nil
        } catch {
            NSLog("AD Player: the sound couldn't be set up: \(error)")
            return "The sound couldn't be set up: \(error.localizedDescription)"
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("AD Player: the sound couldn't be let go: \(error)")
        }
    }
}

/// Playing together, paused or waiting with the screen locked: a silent sound keeps the app running,
/// so it keeps telling the PC where it is (and hears when the others start again).
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?

    func start() {
        if player?.isPlaying == true { return }
        if player == nil {
            guard let p = try? AVAudioPlayer(data: KeepAlive.silence()) else { return }
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            player = p
        }
        Sound.activate()
        player?.play()
    }

    func stop() {
        if player?.isPlaying == true { player?.stop() }
    }

    /// After iPhone's sound system restarted: made again next time.
    func reset() {
        player?.stop()
        player = nil
    }

    /// One second of silence, as a WAV file (8000 Hz, 16-bit, mono).
    private static func silence() -> Data {
        let rate: UInt32 = 8000
        let bytes = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.append(Data(count: Int(bytes)))
        return d
    }
}

/// The last thing played on this phone, kept so the headphones, the car or the lock screen can carry on with it
/// after the app was closed or the phone restarted.
struct LastPlay: Codable {
    var kind: String          // "audio" (an episode or movie) or "book"
    var item: String
    var title: String
    var type: String          // Episode or Movie
    var hasAD: Bool?
    var pos: Double
    var duration: Double

    private static let key = "lastPlay"

    static func note(_ l: LastPlay) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func clear(_ item: String) {
        if load()?.item == item { UserDefaults.standard.removeObject(forKey: key) }
    }

    static func load() -> LastPlay? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastPlay.self, from: d)
    }
}
