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

/// 页面里抓到的图片。图集站往往一个页面几十张，尺寸只有部分能拿到
struct SniffedImage: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let host: String
    let width: Int
    let height: Int

    var sizeText: String {
        guard width > 0, height > 0 else { return "" }
        return "\(width)×\(height)"
    }
}

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
    @Published var images: [SniffedImage] = []
    @Published var errorText: String?
    /// 清爽模式：手动去掉固定浮层、恢复页面滚动
    @Published var cleanMode = false

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

    func addVideo(_ url: String, kindHint: String = "", unverified: Bool = false, first: Bool = false) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count < 2000 else { return }
        guard clean.lowercased().hasPrefix("http") else { return }
        guard found.count < 40 else { return }
        guard !found.contains(where: { $0.url == clean }) else { return }
        let host = URL(string: clean)?.host ?? ""
        // 脚本按返回类型认出来的清单，地址里可能没有后缀，优先用它的判断
        let kind = kindHint.isEmpty ? SniffedVideo.kind(of: clean) : kindHint
        let video = SniffedVideo(url: clean, host: host, kind: kind, unverified: unverified)
        // 播放器正在用的那条放最前面，别被接口里挖出来的可疑地址挤到后面
        if first {
            found.insert(video, at: 0)
        } else {
            found.append(video)
        }
    }

    /// 同时在跑的校验任务上限，接口里的地址一口气全去问会把站点惹毛
    private var verifyingCount = 0

    /// 脚本报上来的地址按来源分级：
    /// 播放器正在用的（element）、响应头认出来的（type）、带后缀的直链都算确认过；
    /// 只有从接口文本里挖出来的（text）才需要问服务器，问不出来也先收下。
    @MainActor
    func acceptVideo(_ url: String, kindHint: String = "", source: String = "") {
        if !kindHint.isEmpty || source == "element" || source == "type"
            || SniffURLValidator.hasMediaSuffix(url) {
            addVideo(url, kindHint: kindHint, first: source == "element")
            return
        }
        guard verifyingCount < 6 else { return }
        verifyingCount += 1
        let referer = urlString
        Task { @MainActor [weak self] in
            defer { self?.verifyingCount -= 1 }
            guard let self else { return }
            let cookie = await self.cookieHeader(for: URL(string: url))
            switch await SniffURLValidator.verify(url, referer: referer, cookie: cookie) {
            case .video(let verified):
                self.addVideo(verified.url, kindHint: verified.kind)
            case .notVideo:
                break
            case .unknown:
                // 403、超时、服务器不认 HEAD 都说明不了它不是视频，
                // 宁可多一条让用户自己点，也别把真地址丢掉
                self.addVideo(url, kindHint: "", unverified: true)
            }
        }
    }

    /// 注入脚本记下的「这一页发过的全部请求」，抓不到东西时用来定位
    @MainActor
    func pageRequests() async -> [String] {
        let js = "JSON.stringify(window.__vlReqs||[])"
        guard let value = try? await webView.evaluateJavaScript(js),
              let raw = value as? String,
              let data = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            guard let address = item["u"] as? String else { return nil }
            let how = item["t"] as? String ?? ""
            return how.isEmpty ? address : "[\(how)] \(address)"
        }
    }

    /// 播放/校验时带上页面登录态：有些站的清单地址要 Cookie 才给正确的片源
    @MainActor
    func cookieHeader(for url: URL?) async -> String? {
        guard let url, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        let now = Date()
        let matched = cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires < now { return false }
            let domain = cookie.domain.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
        guard !matched.isEmpty else { return nil }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func addImage(_ url: String, width: Int, height: Int) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 8, clean.count < 2000 else { return }
        guard clean.lowercased().hasPrefix("http") else { return }
        // 图集站一条帖子几十上百张，80 张明显不够；上限放宽到 600，边滑边补
        guard images.count < 600 else { return }
        guard !images.contains(where: { $0.url == clean }) else { return }
        let host = URL(string: clean)?.host ?? ""
        images.append(SniffedImage(url: clean, host: host, width: width, height: height))
    }

    /// 清爽模式：一次性去掉挡在正文上的浮层，关掉时重载页面复原
    func toggleCleanMode() {
        cleanMode.toggle()
        if cleanMode {
            webView.evaluateJavaScript(BrowserInject.cleanPage, completionHandler: nil)
        } else {
            reload()
        }
        Haptics.light()
    }

    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// 自动往下滚，把懒加载的图片和视频都摇出来；正在滚的时候再调一次就是停
    func toggleAutoScroll() {
        guard webView.url != nil else { return }
        // 先注入定义，再触发；脚本自己判断当前是不是在滚
        webView.evaluateJavaScript(BrowserInject.autoScroll) { [weak self] _, _ in
            guard let self = self else { return }
            self.webView.evaluateJavaScript(
                "window.__vlAutoScroll ? window.__vlAutoScroll(false) : false",
                completionHandler: nil
            )
        }
        Haptics.light()
    }

    func stopAutoScroll() {
        webView.evaluateJavaScript(
            "window.__vlAutoScroll ? window.__vlAutoScroll(true) : false",
            completionHandler: nil
        )
    }

    func showHome() {
        webView.stopLoading()
        found.removeAll()
        images.removeAll()
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
        controller.add(coordinator, name: "imageSniffer")
        controller.add(coordinator, name: "vlGM")
        controller.add(coordinator, name: "vlScript")
        controller.add(coordinator, name: "memoPick")
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
        controller.removeScriptMessageHandler(forName: "imageSniffer")
        controller.removeScriptMessageHandler(forName: "vlGM")
        controller.removeScriptMessageHandler(forName: "vlScript")
        controller.removeScriptMessageHandler(forName: "memoPick")
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
        if message.name == "memoPick" {
            guard let body = message.body as? [String: Any],
                  let text = body["text"] as? String else { return }
            let url = (body["url"] as? String) ?? ""
            let title = (body["title"] as? String) ?? ""
            DispatchQueue.main.async {
                guard let memo = MemoStore.shared.addFromWeb(selection: text,
                                                             pageTitle: title,
                                                             pageURL: url) else { return }
                NotificationCenter.default.post(name: .memoSavedFromWeb, object: memo)
            }
            return
        }
        if message.name == "imageSniffer" {
            guard let body = message.body as? [String: Any],
                  let url = body["url"] as? String else { return }
            let width = (body["width"] as? NSNumber)?.intValue ?? 0
            let height = (body["height"] as? NSNumber)?.intValue ?? 0
            DispatchQueue.main.async {
                self.tab.addImage(url, width: width, height: height)
            }
            return
        }
        guard message.name == "videoSniffer" else { return }

        // 新脚本发的是 {url, kind, src}；旧格式是纯字符串，两种都认
        var address = ""
        var hint = ""
        var source = ""
        if let text = message.body as? String {
            address = text
        } else if let body = message.body as? [String: Any] {
            address = body["url"] as? String ?? ""
            hint = body["kind"] as? String ?? ""
            source = body["src"] as? String ?? ""
        }
        guard !address.isEmpty else { return }

        Task { @MainActor in
            self.tab.acceptVideo(address, kindHint: hint, source: source)
        }
    }

    // MARK: 安装油猴脚本

    /// Greasy Fork 页面里点到「安装此脚本」，直接把代码收进脚本库
    private func installScript(from url: String, in web: WKWebView?) {
        guard let target = URL(string: url), target.scheme?.hasPrefix("http") == true else { return }
        toast("正在下载脚本…", in: web)

        GreasyForkClient.installFromURL(url) { [weak self] code, resolved, error in
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
                documentStart: meta.documentStart,
                sourceURL: resolved ?? url,
                version: meta.version ?? ""
            )
            if let existing = UserscriptLibrary.shared.scripts.first(where: { $0.name == name }) {
                script.id = existing.id
                if script.sourceURL.isEmpty { script.sourceURL = existing.sourceURL }
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

        // 脚本镜像站固定浅色：页面自带的深色变量在这里被压回白底
        applySiteAppearance(webView, host: webView.url?.host)
        webView.evaluateJavaScript(BrowserInject.forceLightSite, completionHandler: nil)

        if let store = store {
            let js = BrowserInject.appearanceJS(night: store.options.night, noImage: store.options.noImage)
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        if tab.cleanMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webView.evaluateJavaScript(BrowserInject.cleanPage, completionHandler: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    /// 脚本站固定浅色渲染（同时把 WebView 底色改白，避免加载间隙透出黑）
    private func applySiteAppearance(_ webView: WKWebView, host: String?) {
        let light = BrowserInject.isLightSite(host)
        webView.overrideUserInterfaceStyle = light ? .light : .unspecified
        let bg: UIColor = light ? .white : .black
        if webView.backgroundColor != bg { webView.backgroundColor = bg }
        if webView.scrollView.backgroundColor != bg { webView.scrollView.backgroundColor = bg }
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
        // 主框架切站时同步外观：脚本站走浅色，其它站跟随系统
        if navigationAction.targetFrame?.isMainFrame ?? false {
            applySiteAppearance(webView, host: url.host)
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

// MARK: - 嗅探地址校验

/// 脚本只能看到「这个地址塞进了 video」，看不到它到底是视频还是页面。
/// 这里补一次轻量请求：按返回头 / 开头几十字节判断，顺便把重定向后的真实地址取回来。
enum SniffURLValidator {

    struct Verified {
        let url: String
        let kind: String
    }

    private struct Reply {
        let response: HTTPURLResponse
        let data: Data
    }

    static func hasMediaSuffix(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        let ext = url.pathExtension.lowercased()
        return ["m3u8", "mp4", "m4v", "mov", "webm", "flv", "mpd"].contains(ext)
    }

    /// 校验结论分三种。只有「明确不是」才该丢，问不出来就交给用户判断——
    /// 上一版把 403 和超时都当成「不是视频」，结果整页一条都不剩。
    enum Verdict {
        case video(Verified)
        case notVideo
        case unknown
    }

    static func verify(_ raw: String, referer: String?, cookie: String?) async -> Verdict {
        guard var comps = URLComponents(string: raw) else { return .unknown }
        comps.fragment = nil
        guard let url = comps.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return .notVideo }

        if let reply = try? await send(url, method: "HEAD", referer: referer, cookie: cookie) {
            // 类型说不清时再走一次 GET，别急着下结论
            switch judge(url, reply, body: nil) {
            case .unknown:
                break
            case let verdict:
                return verdict
            }
        }
        // HEAD 被拒、或不给类型时，只读前 2 KB，足够认出 #EXTM3U
        if let reply = try? await send(url, method: "GET", referer: referer, cookie: cookie, limit: 2048) {
            return judge(url, reply, body: reply.data)
        }
        return .unknown
    }

    private static func send(_ url: URL,
                             method: String,
                             referer: String?,
                             cookie: String?,
                             limit: Int = 0) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 6
        request.setValue(HLSDownloader.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty, URL(string: referer)?.host != nil {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if limit > 0 {
            request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        }

        if method == "HEAD" {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return Reply(response: http, data: Data())
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return Reply(response: http, data: data)
    }

    private static func judge(_ original: URL, _ reply: Reply, body: Data?) -> Verdict {
        guard (200..<400).contains(reply.response.statusCode) else { return .unknown }
        let final = reply.response.url ?? original
        let address = final.absoluteString
        let type = (reply.response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        // 先看正文开头：错误页、JSON、HTML 一律不算视频
        if let body, !body.isEmpty {
            let head = String(decoding: body.prefix(800), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if head.hasPrefix("<!doctype") || head.hasPrefix("<html")
                || head.hasPrefix("{") || head.hasPrefix("[") {
                return .notVideo
            }
            if head.contains("#extm3u") { return .video(Verified(url: address, kind: "HLS")) }
            if head.contains("<mpd") { return .video(Verified(url: address, kind: "DASH")) }
        }

        if type.contains("mpegurl") { return .video(Verified(url: address, kind: "HLS")) }
        if type.contains("dash+xml") { return .video(Verified(url: address, kind: "DASH")) }
        if type.contains("text/html") || type.contains("json") || type.contains("image/")
            || type.contains("javascript") || type.contains("css") {
            return .notVideo
        }
        if type.contains("video/") { return .video(Verified(url: address, kind: "MEDIA")) }
        if type.contains("octet-stream") {
            let length = Int64(reply.response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
            // 又小又没正文，先别信，等 GET 那段确认
            if body == nil, length > 0, length < 2048 { return .unknown }
            return .video(Verified(url: address, kind: "MEDIA"))
        }
        if hasMediaSuffix(address) { return .video(Verified(url: address, kind: "")) }
        return .unknown
    }
}
