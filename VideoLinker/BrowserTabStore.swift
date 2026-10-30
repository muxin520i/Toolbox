import Foundation
import UIKit
import WebKit
import Combine

// MARK: - 浏览器配置

struct BrowserOptions {
    var userAgent: String?
    var adBlock: Bool = true
    var night: Bool = false
    var noImage: Bool = false
    var userscripts: [Userscript] = []
    var engineRaw: String = SearchEngine.baidu.rawValue
    var customSearch: String = ""

    /// 用来判断注入脚本是否需要重新安装
    var scriptSignature: String {
        let list = userscripts
            .filter { $0.enabled && !$0.code.isEmpty }
            .map { $0.signature }
            .joined(separator: "|")
        return "\(list)#ad=\(adBlock)"
    }
}

// MARK: - 单个标签页

final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView
    var coordinator: TabCoordinator?

    @Published var title: String = ""
    @Published var urlString: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var found: [SniffedVideo] = []
    @Published var errorText: String?

    private var bag = Set<AnyCancellable>()

    init(webView: WKWebView, isPrivate: Bool) {
        self.webView = webView
        self.isPrivate = isPrivate
        bind()
    }

    var isHome: Bool { urlString.isEmpty }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: urlString)?.host, !host.isEmpty { return host }
        return "新标签页"
    }

    var hostText: String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var isSecure: Bool {
        (URL(string: urlString)?.scheme ?? "").lowercased() == "https"
    }

    private func bind() {
        webView.publisher(for: \.title)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.title = value ?? "" }
            .store(in: &bag)

        webView.publisher(for: \.url)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self = self else { return }
                guard let url = value, let scheme = url.scheme?.lowercased(),
                      scheme.hasPrefix("http") || scheme == "file" else {
                    self.urlString = ""
                    return
                }
                self.urlString = url.absoluteString
            }
            .store(in: &bag)

        webView.publisher(for: \.canGoBack)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canGoBack = value }
            .store(in: &bag)

        webView.publisher(for: \.canGoForward)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canGoForward = value }
            .store(in: &bag)

        webView.publisher(for: \.isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.isLoading = value }
            .store(in: &bag)

        webView.publisher(for: \.estimatedProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.progress = value }
            .store(in: &bag)
    }

    func addVideo(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count < 2000 else { return }
        guard clean.lowercased().hasPrefix("http") else { return }
        guard found.count < 40 else { return }
        guard !found.contains(where: { $0.url == clean }) else { return }
        let host = URL(string: clean)?.host ?? ""
        found.append(SniffedVideo(url: clean, host: host, kind: SniffedVideo.kind(of: clean)))
    }

    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func showHome() {
        webView.stopLoading()
        found.removeAll()
        errorText = nil
        urlString = ""
        title = ""
        webView.loadHTMLString(
            "<html><head><meta name='viewport' content='width=device-width,initial-scale=1.0'></head><body style='margin:0;background:#0b0b0e'></body></html>",
            baseURL: nil
        )
    }
}

// MARK: - 标签管理

final class BrowserStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []

    @Published var selectedID: UUID = UUID() {
        didSet {
            if oldValue != selectedID { bindCurrent() }
        }
    }

    @Published var privateMode = false
    @Published private(set) var options = BrowserOptions()

    private var currentBag = Set<AnyCancellable>()

    var current: BrowserTab? {
        if let hit = tabs.first(where: { $0.id == selectedID }) { return hit }
        return tabs.first
    }

    var currentIndex: Int {
        guard let tab = current, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return 0 }
        return index
    }

    // MARK: 生命周期

    func bootstrap() {
        guard tabs.isEmpty else { return }
        _ = newTab()
    }

    @discardableResult
    func newTab(url: String? = nil, select: Bool = true) -> BrowserTab {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = privateMode ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore.default()

        let controller = WKUserContentController()
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        if let agent = options.userAgent, !agent.isEmpty {
            web.customUserAgent = agent
        }

        let tab = BrowserTab(webView: web, isPrivate: privateMode)
        let coordinator = TabCoordinator(store: self, tab: tab)
        tab.coordinator = coordinator
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator

        controller.add(coordinator, name: "videoSniffer")
        controller.add(coordinator, name: "vlGM")
        controller.add(coordinator, name: "vlScript")
        BrowserInject.install(into: controller, adBlock: options.adBlock, userscripts: options.userscripts)

        tabs.append(tab)
        if select { selectedID = tab.id }
        if let url = url, !url.isEmpty {
            load(url, in: tab)
        }
        return tab
    }

    func close(_ tab: BrowserTab) {
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil

        // 消息代理是强引用，不解绑会一直活着
        let controller = tab.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "videoSniffer")
        controller.removeScriptMessageHandler(forName: "vlGM")
        controller.removeScriptMessageHandler(forName: "vlScript")
        controller.removeAllUserScripts()

        tab.webView.removeFromSuperview()
        tab.coordinator = nil

        let index = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        tabs.removeAll { $0.id == tab.id }

        if tabs.isEmpty {
            _ = newTab()
            return
        }
        if selectedID == tab.id {
            let next = min(index, tabs.count - 1)
            selectedID = tabs[next].id
        }
    }

    func closeCurrent() {
        guard let tab = current else { return }
        close(tab)
    }

    func select(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        selectedID = tab.id
    }

    func selectNeighbor(offset: Int) {
        guard tabs.count > 1 else { return }
        var index = currentIndex + offset
        if index < 0 { index = tabs.count - 1 }
        if index >= tabs.count { index = 0 }
        selectedID = tabs[index].id
    }

    private func bindCurrent() {
        currentBag.removeAll()
        guard let tab = current else { return }
        tab.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &currentBag)
    }

    // MARK: 设置

    func apply(_ next: BrowserOptions) {
        let uaChanged = next.userAgent != options.userAgent
        let scriptsChanged = next.scriptSignature != options.scriptSignature

        options = next

        for tab in tabs {
            if uaChanged {
                tab.webView.customUserAgent = (next.userAgent?.isEmpty == false) ? next.userAgent : nil
            }
            if scriptsChanged {
                BrowserInject.install(
                    into: tab.webView.configuration.userContentController,
                    adBlock: next.adBlock,
                    userscripts: next.userscripts
                )
                tab.webView.reload()
            }
        }
        if !scriptsChanged {
            applyAppearance()
        }
    }

    func applyAppearance() {
        let js = BrowserInject.appearanceJS(night: options.night, noImage: options.noImage)
        for tab in tabs {
            tab.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: 导航

    static func normalizedURL(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if s.lowercased().hasPrefix("file://") {
            return URL(string: s)
        }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    func load(_ text: String, in target: BrowserTab? = nil) {
        guard let tab = target ?? current,
              let url = Self.normalizedURL(text) else { return }
        tab.errorText = nil
        tab.found.removeAll()
        tab.webView.load(URLRequest(url: url))
    }

    /// 输入框里可能是网址也可能是关键词
    func openSmart(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = Self.normalizedURL(trimmed) {
            load(url.absoluteString)
            return
        }
        if let search = SearchEngine.searchURL(engine: options.engineRaw, custom: options.customSearch, query: trimmed) {
            load(search)
        }
    }
}

// MARK: - 每个标签的导航代理

final class TabCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private unowned let tab: BrowserTab
    private weak var store: BrowserStore?

    init(store: BrowserStore, tab: BrowserTab) {
        self.store = store
        self.tab = tab
        super.init()
    }

    // MARK: 脚本消息

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "vlGM" {
            GMBridge.shared.handle(message.body, webView: message.webView)
            return
        }
        if message.name == "vlScript" {
            guard let url = message.body as? String else { return }
            installScript(from: url, in: message.webView)
            return
        }
        guard message.name == "videoSniffer", let url = message.body as? String else { return }
        DispatchQueue.main.async {
            self.tab.addVideo(url)
        }
    }

    // MARK: 安装油猴脚本

    /// Greasy Fork 页面里点到「安装此脚本」，直接把代码收进脚本库
    private func installScript(from url: String, in web: WKWebView?) {
        guard let target = URL(string: url), target.scheme?.hasPrefix("http") == true else { return }
        toast("正在下载脚本…", in: web)

        GreasyForkClient.installFromURL(url) { [weak self] code, error in
            guard let self = self else { return }
            guard let code = code else {
                self.toast(error ?? "脚本下载失败", in: web)
                return
            }

            guard code.lowercased().contains("==userscript==") else {
                self.toast("这个链接返回的不是脚本代码", in: web)
                return
            }

            let meta = UserscriptParser.parse(code)
            let name = (meta.name?.isEmpty == false ? meta.name! : "未命名脚本")
            var script = Userscript(
                name: name,
                matches: meta.matches.isEmpty ? ["*://*/*"] : meta.matches,
                code: code,
                enabled: true,
                documentStart: meta.documentStart
            )
            if let existing = UserscriptLibrary.shared.scripts.first(where: { $0.name == name }) {
                script.id = existing.id
            }

            UserscriptLibrary.shared.upsert(script)
            self.toast("已安装「\(script.displayName)」，正在刷新…", in: web)
        }
    }

    private func toast(_ text: String, in web: WKWebView?) {
        guard let web = web else { return }
        let safe = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        web.evaluateJavaScript("window.__vlToast && window.__vlToast('\(safe)')", completionHandler: nil)
    }

    // MARK: 导航状态

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab.found.removeAll()
        tab.errorText = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !tab.isPrivate, let text = webView.url?.absoluteString, text.hasPrefix("http") {
            BrowserHistory.shared.record(title: tab.title, url: text)
        }

        webView.evaluateJavaScript(BrowserInject.scanOnce, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            webView.evaluateJavaScript(BrowserInject.scanOnce, completionHandler: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            webView.evaluateJavaScript(BrowserInject.scanOnce, completionHandler: nil)
        }

        if let store = store {
            let js = BrowserInject.appearanceJS(night: store.options.night, noImage: store.options.noImage)
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        DispatchQueue.main.async {
            self.tab.errorText = ns.localizedDescription
        }
    }

    // MARK: 策略

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        let allowed = ["http", "https", "about", "file", "data", "blob"]
        if !allowed.contains(scheme) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // 镜像站有些安装按钮是整页跳转，这里再兜一层：.user.js 一律收进脚本库
        if url.path.lowercased().hasSuffix(".user.js") {
            decisionHandler(.cancel)
            installScript(from: url.absoluteString, in: webView)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        DownloadManager.shared.adopt(
            download,
            source: navigationAction.request.url?.absoluteString ?? ""
        )
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        DownloadManager.shared.adopt(
            download,
            source: navigationResponse.response.url?.absoluteString ?? ""
        )
    }

    // MARK: 新窗口

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if let url = navigationAction.request.url?.absoluteString, !url.isEmpty {
            store?.newTab(url: url)
        }
        return nil
    }

    // MARK: JS 弹窗

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        Self.topController()?.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        Self.topController()?.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        Self.topController()?.present(alert, animated: true)
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        if controller == nil { controller = scene?.windows.first?.rootViewController }
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
