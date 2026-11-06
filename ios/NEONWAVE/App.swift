import UIKit
import WebKit
import SpotifyiOS

/// The NEONWAVE interface lives on GitHub Pages; this app shows it full screen
/// and adds the one thing a web page can't do: wake up the Spotify app.
let appURL = URL(string: "https://evan103837182.github.io/neonwave/")!
let spotifyRedirect = URL(string: "neonwave://callback")!
let neonBG = UIColor(red: 7 / 255, green: 7 / 255, blue: 13 / 255, alpha: 1)

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let web = WebViewController()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = neonBG
        window.rootViewController = web
        window.makeKeyAndVisible()
        self.window = window
        if let url = connectionOptions.urlContexts.first?.url { web.handleReturn(url) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { web.handleReturn(url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        web.becameActive()
    }
}

/// Avoids a retain cycle between WKUserContentController and the view controller.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

final class WebViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var appRemote: SPTAppRemote?
    private var waking = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = neonBG

        let content = WKUserContentController()
        content.add(WeakScriptHandler(self), name: "nw")
        content.addUserScript(WKUserScript(source: "window.NW_NATIVE = true;",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = neonBG
        webView.scrollView.backgroundColor = neonBG
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view.addSubview(webView)
        webView.load(URLRequest(url: appURL))
    }

    // MARK: messages from the page

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "wake":
            wakeSpotify(clientID: body["cid"] as? String ?? "", uri: body["uri"] as? String ?? "")
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s) { UIApplication.shared.open(url) }
        case "reload":
            webView.load(URLRequest(url: appURL))
        default:
            break
        }
    }

    /// Opens Spotify, starts `uri` (or the last song if empty) and bounces back here.
    private func wakeSpotify(clientID: String, uri: String) {
        guard !clientID.isEmpty else { reportWake(ok: false, error: "No Client ID set"); return }
        let remote = SPTAppRemote(configuration: SPTConfiguration(clientID: clientID, redirectURL: spotifyRedirect),
                                  logLevel: .none)
        appRemote = remote
        waking = true
        remote.authorizeAndPlayURI(uri) { [weak self] canTry in
            if !canTry {
                self?.waking = false
                self?.reportWake(ok: false, error: "Spotify app isn't installed")
            }
        }
    }

    func handleReturn(_ url: URL) {
        guard url.scheme?.lowercased() == "neonwave" else { return }
        let params = appRemote?.authorizationParameters(from: url)
        let error = params?[SPTAppRemoteErrorDescriptionKey]
        waking = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.reportWake(ok: error == nil, error: error) }
    }

    func becameActive() {
        if waking {
            // Came back from Spotify without the redirect (user switched back by hand).
            waking = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.reportWake(ok: true, error: nil) }
        }
        runJS("window.nwActive && window.nwActive()")
    }

    private func reportWake(ok: Bool, error: String?) {
        let err = error.map { "'" + $0.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "'", with: "") + "'" } ?? "null"
        runJS("window.nwWoke && window.nwWoke(\(ok), \(err))")
    }

    private func runJS(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { decisionHandler(.allow); return }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { decisionHandler(.allow); return }
        UIApplication.shared.open(url) // spotify: links and other app links
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        webView.loadHTMLString(offlinePage, baseURL: nil)
    }

    private let offlinePage = """
    <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body style="background:#07070d;color:#ececf4;font-family:-apple-system,sans-serif;display:flex;
    flex-direction:column;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center">
    <div style="font-size:40px;font-weight:800;color:#ff2a6d;letter-spacing:4px">NO SIGNAL</div>
    <p style="color:#8a8aa6;max-width:260px">Can't reach NEONWAVE. Check your internet connection.</p>
    <button onclick="webkit.messageHandlers.nw.postMessage({cmd:'reload'})"
    style="background:#fcee0a;border:0;padding:14px 28px;font-weight:800;letter-spacing:2px">RETRY</button>
    </body></html>
    """
}
