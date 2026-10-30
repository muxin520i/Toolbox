import SwiftUI
import WebKit
import Combine

// MARK: - 嗅探结果

struct SniffedVideo: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let host: String
    let kind: String

    var displayName: String {
        guard let u = URL(string: url) else { return url }
        var name = u.lastPathComponent
        if name.isEmpty || name == "/" {
            name = u.host ?? url
        }
        if let decoded = name.removingPercentEncoding {
            name = decoded
        }
        if name.count > 42 {
            name = String(name.prefix(42)) + "…"
        }
        return name
    }

    static func kind(of url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return "HLS" }
        if lower.contains(".mp4") { return "MP4" }
        if lower.contains(".m4v") || lower.contains(".mov") { return "MOV" }
        if lower.contains(".webm") { return "WEBM" }
        if lower.contains(".flv") { return "FLV" }
        return "VIDEO"
    }
}

// MARK: - 嗅探模型

final class SnifferModel: NSObject, ObservableObject {
    @Published var found: [SniffedVideo] = []
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var pageTitle: String = ""
    @Published var currentURLString: String = ""
    @Published var canGoBack = false

    weak var webView: WKWebView?
    private var cancellables = Set<AnyCancellable>()

    func attach(_ webView: WKWebView) {
        self.webView = webView

        webView.publisher(for: \.estimatedProgress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.progress = value }
            .store(in: &cancellables)

        webView.publisher(for: \.isLoading)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isLoading = value }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoBack)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canGoBack = value }
            .store(in: &cancellables)

        webView.publisher(for: \.title)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.pageTitle = value ?? "" }
            .store(in: &cancellables)

        webView.publisher(for: \.url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let url = value else { return }
                self?.currentURLString = url.absoluteString
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func open(_ text: String) -> Bool {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return false }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), let host = url.host, host.contains(".") else { return false }
        found.removeAll()
        currentURLString = url.absoluteString
        webView?.load(URLRequest(url: url))
        return true
    }

    func reload() {
        webView?.reload()
    }

    func goBack() {
        webView?.goBack()
    }

    func add(_ raw: String) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count < 2000 else { return }
        guard found.count < 40 else { return }
        guard !found.contains(where: { $0.url == clean }) else { return }
        guard clean.lowercased().hasPrefix("http") else { return }

        let host = URL(string: clean)?.host ?? ""
        let video = SniffedVideo(url: clean, host: host, kind: SniffedVideo.kind(of: clean))
        found.append(video)
    }
}

// MARK: - 注入脚本

enum SnifferScript {
    /// 页面一开始就加载：劫持 fetch / XHR，并持续扫描 video 标签
    static let source = """
    (function() {
      if (window.__vlHooked) { return; }
      window.__vlHooked = true;

      function send(u) {
        try {
          if (!u || typeof u !== 'string') { return; }
          if (!/^https?:/i.test(u)) { return; }
          if (!/\\.(m3u8|mp4|m4v|mov|webm|flv)(\\?|#|$)/i.test(u)) { return; }
          window.webkit.messageHandlers.videoSniffer.postMessage(u);
        } catch (e) {}
      }

      function scan() {
        try {
          var nodes = document.querySelectorAll('video, source, audio');
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            send(el.currentSrc || el.src || el.getAttribute('data-src') || '');
          }
        } catch (e) {}
      }

      window.__vlScan = scan;
      scan();
      setInterval(scan, 2000);

      try {
        new MutationObserver(scan).observe(document.documentElement, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src']
        });
      } catch (e) {}

      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function(input, init) {
          try {
            send(typeof input === 'string' ? input : (input && input.url));
          } catch (e) {}
          var promise = origFetch.apply(this, arguments);
          try {
            promise.then(function(res) {
              try { send(res && res.url); } catch (e) {}
            });
          } catch (e) {}
          return promise;
        };
      }

      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        try { send(url); } catch (e) {}
        return origOpen.apply(this, arguments);
      };
    })();
    """

    static let scanOnce = "if (window.__vlScan) { window.__vlScan(); }"
}

// MARK: - WKWebView 包装

struct SnifferWebView: UIViewRepresentable {
    @ObservedObject var model: SnifferModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(
                source: SnifferScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        contentController.add(context.coordinator, name: "videoSniffer")
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        model.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let model: SnifferModel

        init(model: SnifferModel) {
            self.model = model
        }

        // 接收 JS 发来的地址
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "videoSniffer", let url = message.body as? String else { return }
            DispatchQueue.main.async {
                self.model.add(url)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.model.found.removeAll()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(SnifferScript.scanOnce, completionHandler: nil)

            // 懒加载的视频常常晚一步出现，补两次扫描
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                webView.evaluateJavaScript(SnifferScript.scanOnce, completionHandler: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                webView.evaluateJavaScript(SnifferScript.scanOnce, completionHandler: nil)
            }
        }

        // 处理 target="_blank"，直接在同一个 webView 里打开
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

// MARK: - 嗅探页面

struct SnifferView: View {
    @StateObject private var model = SnifferModel()
    @State private var address = ""
    @State private var request: PlayRequest?
    @FocusState private var addressFocused: Bool

    private var hasPage: Bool { !model.currentURLString.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(red: 0.03, green: 0.03, blue: 0.04).ignoresSafeArea()

                VStack(spacing: 0) {
                    addressBar

                    ZStack(alignment: .top) {
                        SnifferWebView(model: model)

                        if model.isLoading {
                            ProgressView(value: max(0.03, model.progress))
                                .progressViewStyle(.linear)
                                .tint(Color(red: 1.0, green: 0.55, blue: 0.45))
                        }

                        if !hasPage {
                            startHint
                        }
                    }
                }

                if !model.found.isEmpty {
                    resultsBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("网页嗅探")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.045, green: 0.045, blue: 0.06), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .animation(.easeInOut(duration: 0.22), value: model.found.count)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $request) { req in
            PlayerScreen(request: req)
        }
    }

    // MARK: 地址栏

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.canGoBack ? .white.opacity(0.8) : .white.opacity(0.2))
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoBack)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))

                TextField("", text: $address, prompt: Text("输入网址，例如 example.com").foregroundColor(.white.opacity(0.28)))
                    .focused($addressFocused)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .onSubmit { go() }

                if model.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Button {
                go()
            } label: {
                Text("前往")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.42, blue: 0.31),
                                     Color(red: 0.55, green: 0.28, blue: 0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.05, green: 0.05, blue: 0.07))
    }

    // MARK: 初始提示

    private var startHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "safari")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.16))
            Text("打开一个网页，自动找出里面的视频")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("在地址栏输入网址，页面里出现的 m3u8 / mp4 地址会被自动捕获，\n直接点开就能播。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Text("提示：视频站点频繁改版，反爬和加密链接可能导致抓不到。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.22))
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.03, green: 0.03, blue: 0.04))
    }

    // MARK: 结果条

    private var resultsBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.45, blue: 0.35))
                    .frame(width: 6, height: 6)
                Text("发现 \(model.found.count) 个视频")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button("清空") {
                    model.found.removeAll()
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.found) { video in
                        Button {
                            open(video)
                        } label: {
                            resultCard(video)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func resultCard(_ video: SniffedVideo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(video.kind)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color(red: 1.0, green: 0.42, blue: 0.31).opacity(0.85))
                    )
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Text(video.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 148, alignment: .leading)

            Text(video.host)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.32))
                .lineLimit(1)
                .frame(width: 148, alignment: .leading)
        }
        .padding(10)
        .frame(width: 168, height: 92, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 动作

    private func go() {
        addressFocused = false
        if model.open(address) {
            address = model.currentURLString
        }
    }

    private func open(_ video: SniffedVideo) {
        guard let url = URL(string: video.url) else { return }
        request = PlayRequest(url: url)
    }
}

struct SnifferView_Previews: PreviewProvider {
    static var previews: some View {
        SnifferView()
    }
}
