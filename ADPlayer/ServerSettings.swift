#if os(iOS)
import SwiftUI
import WebKit

/// The server's own settings page, for whoever runs it (the public server sends "admin" in /api/play/me; the PC app at
/// home never does). It opens inside the app: the app asks the server for a one-time link with its sign-in, and the page
/// opens signed in.
struct ServerSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var url: URL?
    @State private var problem = ""

    var body: some View {
        Group {
            if let url = url {
                AdminWebView(url: url, home: model.api?.base)
            } else if !problem.isEmpty {
                Text(problem).padding()
            } else {
                ProgressView("Opening the server's settings…")
            }
        }
        .navigationTitle("Server settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let api = model.api else { problem = "There's no server set up."; return }
            do {
                let r = try await api.post("api/play/admin/link", [:], as: AdminLink.self)
                if let u = r.url, let full = api.media(u) { url = full } else { problem = r.error ?? "Couldn't open the server's settings." }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The page itself. Only the server's own pages open here; any other link opens in Safari.
struct AdminWebView: UIViewRepresentable {
    let url: URL
    let home: URL?

    func makeCoordinator() -> Coordinator { Coordinator(home: home) }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.navigationDelegate = context.coordinator
        w.allowsBackForwardNavigationGestures = true
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let home: URL?
        init(home: URL?) { self.home = home }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let u = action.request.url, let h = home, action.navigationType == .linkActivated,
                  u.host != h.host || u.port != h.port else { decisionHandler(.allow); return }
            UIApplication.shared.open(u)
            decisionHandler(.cancel)
        }
    }
}
#endif
