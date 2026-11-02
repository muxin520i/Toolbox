import UIKit
import UniformTypeIdentifiers

/// 分享扩展：在 Safari、微信、B 站等任何 App 的分享面板里出现，
/// 把链接直接交给主 App 播放或下载。
final class ShareViewController: UIViewController {

    private var link: String?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let previewLabel = UILabel()
    private let statusLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        extractLink()
    }

    // MARK: - 界面

    private func setupUI() {
        view.backgroundColor = .clear

        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 18
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        titleLabel.text = "发送到工具箱"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        previewLabel.text = "正在读取链接…"
        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 3
        previewLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = ""
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        style(playButton, title: "播放", filled: true)
        style(downloadButton, title: "下载", filled: false)

        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [playButton, downloadButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 14)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        for item in [titleLabel, previewLabel, statusLabel, buttons, cancelButton] {
            card.addSubview(item)
        }

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            previewLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            buttons.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 44),

            cancelButton.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            cancelButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 30),
            cancelButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        preferredContentSize = CGSize(width: 0, height: 340)
    }

    private func style(_ button: UIButton, title: String, filled: Bool) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.layer.cornerRadius = 11
        if filled {
            button.backgroundColor = UIColor.systemBlue
            button.setTitleColor(.white, for: .normal)
        } else {
            button.backgroundColor = UIColor.secondarySystemBackground
            button.setTitleColor(.label, for: .normal)
        }
    }

    // MARK: - 取链接

    private func extractLink() {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        guard !attachments.isEmpty else {
            showError("没有拿到内容")
            return
        }

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                    if let url = item as? URL {
                        self?.accept(url.absoluteString)
                    } else if let data = item as? Data,
                              let text = String(data: data, encoding: .utf8) {
                        self?.accept(text)
                    }
                }
                return
            }
        }

        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                if let text = item as? String {
                    self?.accept(text)
                } else if let data = item as? Data,
                          let text = String(data: data, encoding: .utf8) {
                    self?.accept(text)
                }
            }
            return
        }

        showError("这个内容里没有链接")
    }

    private func accept(_ raw: String) {
        guard let found = Self.firstURL(in: raw) else {
            showError("这段内容里没有可用的链接")
            return
        }
        DispatchQueue.main.async {
            self.link = found
            self.previewLabel.text = found
            self.statusLabel.text = ""
            self.playButton.isEnabled = true
            self.downloadButton.isEnabled = true
        }
    }

    private static func firstURL(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return trimmed
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let match = detector.firstMatch(in: trimmed, options: [], range: range)
        guard let url = match?.url else { return nil }
        return url.absoluteString
    }

    private func showError(_ text: String) {
        DispatchQueue.main.async {
            self.previewLabel.text = "没有可发送的链接"
            self.statusLabel.text = text
            self.playButton.isEnabled = false
            self.downloadButton.isEnabled = false
        }
    }

    // MARK: - 动作

    @objc private func playTapped() { send(action: "play") }
    @objc private func downloadTapped() { send(action: "download") }

    private func send(action: String) {
        guard let link, !link.isEmpty else { return }

        // 先把链接放进剪贴板：从 iOS 18 起，分享扩展已经拉不起主 App 了，
        // 这条路才是真正能走通的兜底，主 App 回到前台会自动提示。
        // 同时写成文本和 URL 两种表示：主 App 用 hasURLs 判断有没有链接（不会弹粘贴授权），
        // 别的 App 直接粘贴也能拿到文本。
        if let url = URL(string: link) {
            UIPasteboard.general.items = [[
                "public.utf8-plain-text": link,
                "public.url": url
            ]]
        } else {
            UIPasteboard.general.string = link
        }

        guard let deepLink = Self.deepLink(action: action, url: link) else { return }

        // 1) iOS 17 及更早还能顺着响应链找到能执行 openURL: 的对象，先试这条（能成就直接跳）
        if openViaResponderChain(deepLink) {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        // 2) 官方入口，只有少数扩展点放行，分享扩展基本都会被拒
        extensionContext?.open(deepLink) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.showHandoffHint()
                }
            }
        }
    }

    private static func deepLink(action: String, url: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "videolinker"
        comps.host = "open"
        comps.queryItems = [
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "url", value: url)
        ]
        return comps.url
    }

    /// 扩展里没有 UIApplication.shared，只能顺着响应链找宿主 App 的 UIApplication。
    /// iOS 17 及以前有效；iOS 18 起系统把这条路也堵了，返回 false 就走剪贴板。
    private func openViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication, app.responds(to: selector) {
                app.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// 跳不过去时的收尾：说清楚下一步该干什么，别让用户以为没反应
    private func showHandoffHint() {
        statusLabel.text = "iOS 不允许分享面板直接打开 App。链接已复制，回到桌面打开「工具箱」，首页会弹出提示，点一下就能播。"
        playButton.isEnabled = false
        downloadButton.isEnabled = false
        playButton.alpha = 0.5
        downloadButton.alpha = 0.5
        cancelButton.setTitle("完成", for: .normal)
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: NSError(domain: "ToolboxShare", code: 0))
    }
}
