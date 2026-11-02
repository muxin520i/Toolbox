import SwiftUI
import WebKit

// MARK: - 注入脚本

enum BrowserInject {

    /// 视频地址抓取：劫持 fetch / XHR，持续扫描 video 标签
    static let sniffer = """
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
        scanImages();
      }

      function sendImage(u, w, h) {
        try {
          if (!u || typeof u !== 'string') { return; }
          if (!/^https?:/i.test(u)) { return; }
          if (u.length > 2000) { return; }
          window.webkit.messageHandlers.imageSniffer.postMessage({ url: u, width: w || 0, height: h || 0 });
        } catch (e) {}
      }

      // srcset 里挑最大的那张，图集站常常 1x / 2x 各一份
      function bestFromSrcset(el) {
        try {
          var ss = el.getAttribute('srcset');
          if (!ss) { return ''; }
          var best = '';
          var bestW = -1;
          var parts = ss.split(',');
          for (var i = 0; i < parts.length; i++) {
            var seg = parts[i].trim();
            if (!seg) { continue; }
            var bits = seg.split(/\\s+/);
            var u = bits[0];
            var w = 0;
            if (bits.length > 1) {
              var d = bits[1];
              if (/^\\d+w$/.test(d)) { w = parseInt(d, 10); }
              else if (/^\\d+(\\.\\d+)?x$/.test(d)) { w = parseFloat(d) * 1000; }
            }
            if (w > bestW) { bestW = w; best = u; }
          }
          return best;
        } catch (e) { return ''; }
      }

      function scanImages() {
        try {
          var imgs = document.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            var el = imgs[i];
            var w = el.naturalWidth || 0;
            var h = el.naturalHeight || 0;
            // 已知尺寸的小图多半是图标 / 表情
            if (w && h && (w < 220 || h < 220)) { continue; }
            var u = bestFromSrcset(el) || el.currentSrc || el.src
              || el.getAttribute('data-src') || el.getAttribute('data-original') || '';
            sendImage(u, w, h);
          }

          // 图集站常常是 <a href="xxx.jpg"><img ...></a>，链接也算一张
          var links = document.querySelectorAll('a[href]');
          for (var j = 0; j < links.length; j++) {
            var href = links[j].getAttribute('href') || '';
            if (!/\\.(jpe?g|png|webp|gif|bmp|avif)(\\?|#|$)/i.test(href)) { continue; }
            sendImage(links[j].href || href, 0, 0);
          }

          var metas = document.querySelectorAll('meta[property="og:image"], meta[name="og:image"]');
          for (var k = 0; k < metas.length; k++) {
            sendImage(metas[k].getAttribute('content') || '', 0, 0);
          }
        } catch (e) {}
      }

      window.__vlScan = scan;
      window.__vlScanImages = scanImages;
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

    /// 轻量广告过滤
    static let adBlockScript = """
    (function() {
      if (window.__vlAdBlock) { return; }
      window.__vlAdBlock = true;

      var selectors = [
        '[class*="adsbygoogle"]', '[id*="adsbygoogle"]',
        '[class*="advert"]', '[id*="advert"]',
        '[class*="ad-banner"]', '[id*="ad-banner"]',
        '[class*="banner-ad"]', '[id*="banner-ad"]',
        '[class*="popup-ad"]', '[id*="popup-ad"]',
        '.ad', '.ads', '.ad-box', '.ad-wrap', '.ad-container'
      ];

      function clean() {
        for (var i = 0; i < selectors.length; i++) {
          var nodes = document.querySelectorAll(selectors[i]);
          for (var j = 0; j < nodes.length; j++) {
            var el = nodes[j];
            if (!el || el.tagName === 'VIDEO' || el.tagName === 'SOURCE') { continue; }
            el.style.setProperty('display', 'none', 'important');
          }
        }
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', clean);
      } else {
        clean();
      }
      setInterval(clean, 2000);

      window.open = function(u) {
        try { if (u && typeof u === 'string') { window.location.href = u; } } catch (e) {}
        return null;
      };
    })();
    """

    /// 夜间 / 无图（自包含，可重复执行，幂等）
    static let appearanceFn = """
    window.__vlAppearance = function(night, noImage) {
      try {
        var root = document.documentElement;
        var head = document.head || root;
        var n = document.getElementById('vl-night-style');

        // 脚本镜像站整体强制浅色：系统深色模式会把 Bulma 的深色变量带出来，
        // 页面会变成黑底，这里统一压回白底，并跳过夜间反色
        var host = (location.hostname || '').toLowerCase();
        var forceLight = /(^|\\.)greasyfork\\.(icu|org\\.cn)$/.test(host)
          || /(^|\\.)greasyfork\\.org$/.test(host);
        var lightStyle = document.getElementById('vl-force-light');

        if (forceLight) {
          if (!lightStyle) {
            lightStyle = document.createElement('style');
            lightStyle.id = 'vl-force-light';
            lightStyle.textContent =
              'html{color-scheme:light!important;background:#fff!important}'
              + 'body{background:#fff!important;color:#1b1f27!important}'
              + ':root{--bulma-scheme-main-l:100%!important;--bulma-scheme-main-bis-l:98%!important;'
              + '--bulma-scheme-main-ter-l:96%!important;--bulma-background-l:96%!important;'
              + '--bulma-text-l:21%!important;--bulma-text-strong-l:14%!important;'
              + '--bulma-border-l:86%!important;--bulma-scheme-invert-l:21%!important}'
              + 'html[data-vl-night]{filter:none!important}';
          }
          if (!lightStyle.parentNode) { head.appendChild(lightStyle); }
          if (n && n.parentNode) { n.parentNode.removeChild(n); }
          n = null;
          root.removeAttribute('data-vl-night');
          night = false;
        } else if (lightStyle && lightStyle.parentNode) {
          lightStyle.parentNode.removeChild(lightStyle);
        }

        function pageIsDark() {
          try {
            var els = [document.body, root];
            for (var i = 0; i < els.length; i++) {
              if (!els[i]) { continue; }
              var bg = getComputedStyle(els[i]).backgroundColor || '';
              var m = bg.match(/[\\d.]+/g);
              if (!m || m.length < 3) { continue; }
              var a = m.length >= 4 ? parseFloat(m[3]) : 1;
              if (a < 0.1) { continue; }
              var lum = (0.2126 * parseFloat(m[0]) + 0.7152 * parseFloat(m[1]) + 0.0722 * parseFloat(m[2])) / 255;
              return lum < 0.42;
            }
            return false;
          } catch (e) { return false; }
        }

        var prev = root.getAttribute('data-vl-night');

        if (night && !pageIsDark()) {
          if (!n) {
            n = document.createElement('style');
            n.id = 'vl-night-style';
            n.textContent = 'html{filter:invert(1) hue-rotate(180deg)!important;background-color:#fff!important;color-scheme:light!important}'
              + 'img,video,picture,canvas,svg,iframe,[style*="background-image"]{filter:invert(1) hue-rotate(180deg)!important}';
          }
          if (!n.parentNode) { head.appendChild(n); }
          root.setAttribute('data-vl-night', 'on');
        } else if (night) {
          // 站点本身是深色，不做反色，只提示一次
          if (prev !== 'skip') {
            root.setAttribute('data-vl-night', 'skip');
            if (window.__vlToast) { window.__vlToast('这个网站本身是深色，无需反色'); }
          }
        } else {
          if (n && n.parentNode) { n.parentNode.removeChild(n); }
          root.removeAttribute('data-vl-night');
        }

        var m2 = document.getElementById('vl-noimg-style');
        if (noImage) {
          if (!m2) {
            m2 = document.createElement('style');
            m2.id = 'vl-noimg-style';
            m2.textContent = 'img,picture,svg image{visibility:hidden!important}';
          }
          if (!m2.parentNode) { head.appendChild(m2); }
        } else if (m2 && m2.parentNode) {
          m2.parentNode.removeChild(m2);
        }
      } catch (e) {}
    };
    """

    /// 页面内提示条 + 阅读模式
    static let shell = """
    (function() {
    \(appearanceFn)

      window.__vlToast = function(text) {
        try {
          var el = document.getElementById('vl-toast');
          if (!el) {
            el = document.createElement('div');
            el.id = 'vl-toast';
            el.style.cssText = 'position:fixed;left:50%;bottom:88px;transform:translateX(-50%);'
              + 'max-width:78%;padding:10px 16px;border-radius:12px;background:rgba(0,0,0,.82);'
              + 'color:#fff;font-size:13px;line-height:1.5;z-index:2147483647;'
              + 'transition:opacity .25s;pointer-events:none;text-align:center;word-break:break-all;';
            (document.body || document.documentElement).appendChild(el);
          }
          el.textContent = text;
          el.style.opacity = '1';
          if (el.__hideTimer) { clearTimeout(el.__hideTimer); }
          el.__hideTimer = setTimeout(function() { el.style.opacity = '0'; }, 2600);
        } catch (e) {}
      };

      window.__vlReader = function() {
        try {
          if (document.getElementById('vl-reader-on')) { return true; }
          var target = document.querySelector('article') || document.querySelector('main') || document.querySelector('[role="main"]');
          if (!target) {
            var nodes = document.querySelectorAll('div,section');
            var bestLen = 0;
            for (var i = 0; i < nodes.length; i++) {
              var text = nodes[i].innerText || '';
              if (text.length > bestLen && nodes[i].querySelectorAll('p').length >= 3) {
                target = nodes[i];
                bestLen = text.length;
              }
            }
          }
          if (!target) { return false; }
          if (((target.innerText || '').length) < 220) { return false; }

          var html = target.innerHTML;
          var title = document.title || '';
          var safe = title.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
          document.body.innerHTML = '<div id="vl-reader-on" style="max-width:680px;margin:0 auto;padding:24px 18px 60px;font-size:18px;line-height:1.85;font-family:-apple-system,system-ui,sans-serif">'
            + '<h1 style="font-size:22px;line-height:1.45;margin:0 0 18px">' + safe + '</h1>' + html + '</div>';
          document.body.style.background = '#f7f7f8';
          document.body.style.color = '#1a1a1a';
          document.documentElement.style.overflow = 'auto';
          return true;
        } catch (e) { return false; }
      };
    })();
    """

    static let scanOnce = "if (window.__vlScan) { window.__vlScan(); }"

    /// Greasy Fork 安装拦截：点到 .user.js 时交给原生侧导入脚本库，不走下载
    static let installHook = """
    (function() {
      if (window.__vlInstallHook) { return; }
      window.__vlInstallHook = true;

      function isScript(u) {
        return typeof u === 'string' && /\\.user\\.js(\\?|#|$)/i.test(u);
      }

      function post(u) {
        try { window.webkit.messageHandlers.vlScript.postMessage(u); } catch (e) {}
      }

      document.addEventListener('click', function(ev) {
        try {
          var node = ev.target;
          while (node && node.tagName !== 'A') { node = node.parentNode; }
          if (!node) { return; }
          var href = node.getAttribute('href') || '';
          if (!isScript(href) && !isScript(node.href)) { return; }
          ev.preventDefault();
          ev.stopPropagation();
          post(node.href || href);
        } catch (e) {}
      }, true);

      var origOpen = window.open;
      window.open = function(u) {
        if (isScript(u)) { post(u); return null; }
        return origOpen ? origOpen.apply(this, arguments) : null;
      };
    })();
    """

    static let readerRun = "window.__vlReader ? window.__vlReader() : false"

    /// 脚本镜像站：这些站点一律按浅色渲染，避免跟随系统深色变黑
    static func isLightSite(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        if h == "greasyfork.icu" || h.hasSuffix(".greasyfork.icu") { return true }
        if h == "greasyfork.org" || h.hasSuffix(".greasyfork.org") { return true }
        if h == "greasyfork.org.cn" || h.hasSuffix(".greasyfork.org.cn") { return true }
        return false
    }

    /// 兜底：页面自身写死了深色 class/样式时，再把主背景压白一遍
    static let forceLightSite = """
    (function() {
      try {
        var host = (location.hostname || '').toLowerCase();
        var hit = /(^|\\.)greasyfork\\.(icu|org\\.cn)$/.test(host) || /(^|\\.)greasyfork\\.org$/.test(host);
        if (!hit) { return; }
        if (document.getElementById('vl-force-light')) { return; }
        var s = document.createElement('style');
        s.id = 'vl-force-light';
        s.textContent = 'html{color-scheme:light!important;background:#fff!important}'
          + 'body{background:#fff!important;color:#1b1f27!important}'
          + ':root{--bulma-scheme-main-l:100%!important;--bulma-scheme-main-bis-l:98%!important;'
          + '--bulma-scheme-main-ter-l:96%!important;--bulma-background-l:96%!important;'
          + '--bulma-text-l:21%!important;--bulma-text-strong-l:14%!important;'
          + '--bulma-border-l:86%!important;--bulma-scheme-invert-l:21%!important}';
        (document.head || document.documentElement).appendChild(s);
        document.documentElement.removeAttribute('data-vl-night');
        var n = document.getElementById('vl-night-style');
        if (n && n.parentNode) { n.parentNode.removeChild(n); }
      } catch (e) {}
    })();
    """

    static func appearanceJS(night: Bool, noImage: Bool) -> String {
        let a = night ? "true" : "false"
        let b = noImage ? "true" : "false"
        // 每次都带上函数定义，页面重绘或脚本丢失时也能立刻恢复
        return appearanceFn + "\nwindow.__vlAppearance(\(a), \(b));"
    }

    /// 统一装配所有注入脚本
    static func install(into controller: WKUserContentController,
                        adBlock: Bool,
                        userscripts: [Userscript]) {
        controller.removeAllUserScripts()

        let startScripts = [sniffer, shell, adBlock ? adBlockScript : "", installHook, forceLightSite].filter { !$0.isEmpty }
        for code in startScripts {
            controller.addUserScript(
                WKUserScript(source: code, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }

        guard !userscripts.isEmpty else { return }

        controller.addUserScript(
            WKUserScript(source: GMShim.source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        for script in userscripts where script.enabled && !script.code.isEmpty {
            controller.addUserScript(
                WKUserScript(
                    source: UserscriptEngine.injectionJS(for: script),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }
    }
}

// MARK: - WebView 容器

/// 把当前标签的 WKWebView 挂到 SwiftUI 里，切标签时换掉
final class WebHostView: UIView {
    private weak var attached: WKWebView?

    func attach(_ web: WKWebView) {
        guard attached !== web else { return }
        attached?.removeFromSuperview()

        if web.scrollView.refreshControl == nil {
            let control = UIRefreshControl()
            control.tintColor = UIColor.lightGray
            control.addTarget(self, action: #selector(handleRefresh(_:)), for: .valueChanged)
            web.scrollView.refreshControl = control
        }

        web.frame = bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(web)
        attached = web
    }

    @objc private func handleRefresh(_ sender: UIRefreshControl) {
        attached?.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            sender.endRefreshing()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attached?.frame = bounds
    }
}

struct BrowserWebHost: UIViewRepresentable {
    @ObservedObject var store: BrowserStore

    func makeUIView(context: Context) -> WebHostView {
        WebHostView()
    }

    func updateUIView(_ host: WebHostView, context: Context) {
        guard let web = store.current?.webView else { return }
        host.attach(web)
    }
}
