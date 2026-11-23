import SwiftUI
import AVKit

/// The video on the Apple TV: Apple's own player (the Siri Remote's scrubbing, the info panel), with the
/// sound tracks (audio description first) and Stats for nerds in its menu. The Menu button closes it.
struct TVPlayer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var video: VideoModel
    @State private var tracks: [TrackList.Track] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVPlayerController(video: video, tracks: tracks).ignoresSafeArea()
            if video.stats {
                StatsPanel(video: video).padding(60).allowsHitTesting(false)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: video.item?.id) {
            guard let api = model.api, let it = video.item else { return }
            tracks = (try? await api.get("api/play/tracks", ["id": it.id], as: TrackList.self).audio) ?? []
        }
    }
}

struct TVPlayerController: UIViewControllerRepresentable {
    @ObservedObject var video: VideoModel
    let tracks: [TrackList.Track]

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = video.player
        return c
    }

    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {
        if c.player !== video.player { c.player = video.player }
        let v = video
        var items: [UIMenuElement] = []
        let choices: [UIAction] = tracks.compactMap { t in
            guard let i = t.index else { return nil }
            return UIAction(title: t.label, image: t.ad == true ? UIImage(systemName: "ear") : nil, state: i == v.aidx ? .on : .off) { _ in
                Task { @MainActor in v.switchAudio(i) }
            }
        }
        if choices.count > 1 {
            items.append(UIMenu(title: "Sound track", image: UIImage(systemName: "waveform"), children: choices))
        }
        items.append(UIAction(title: "Stats for nerds", image: UIImage(systemName: "chart.bar"), state: v.stats ? .on : .off) { _ in
            Task { @MainActor in
                v.stats.toggle()
                v.model?.announce(v.stats ? "Stats for nerds on." : "Stats off.")
            }
        })
        c.transportBarCustomMenuItems = items
        // the name in the player's info panel
        if let it = c.player?.currentItem, !v.title.isEmpty,
           (it.externalMetadata.first { $0.identifier == .commonIdentifierTitle }?.stringValue) != v.title {
            let m = AVMutableMetadataItem()
            m.identifier = .commonIdentifierTitle
            m.value = v.title as NSString
            m.extendedLanguageTag = "und"
            it.externalMetadata = [m]
        }
    }
}
