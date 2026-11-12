import SwiftUI
import WebKit

// MARK: - 注入脚本

enum BrowserInject {

    /// 视频地址抓取：劫持 fetch / XHR，持续扫描 video 标签
    static let sniffer = """
    (function() {
      if (window.__vlHooked) { return; }
      window.__vlHooked = true;

      var posted = {};

      // 相对地址、协议相对地址都补全；blob / data 不是能下载的链接
      function abs(u) {
        try {
          if (!u || typeof u !== 'string') { return ''; }
          u = u.trim();
          if (!u) { return ''; }
          if (/^(blob|data|javascript|about|mailto):/i.test(u)) { return ''; }
          var a = new URL(u, location.href);
          if (a.protocol !== 'http:' && a.protocol !== 'https:') { return ''; }
          return a.href;
        } catch (e) { return ''; }
      }

      // 页面发过的全部请求，诊断用，只留最近 400 条
      var reqs = [];
      window.__vlReqs = reqs;
      function note(u, how) {
        try {
          u = abs(u);
          if (!u) { return; }
          if (reqs.length > 400) { return; }
          for (var i = 0; i < reqs.length; i++) { if (reqs[i].u === u) { return; } }
          reqs.push({ u: u, t: how || '' });
        } catch (e) {}
      }

      // src 说明地址是从哪发现的：element 最可信（播放器真的在用它），
      // text 最不可信（可能只是接口 JSON 里的一句话），交给原生侧分级处理。
      // 同一个地址会被多条线抓到，只报一次，保留最可信的那个来源
      var srcRank = { element: 4, type: 3, json: 2, url: 2, text: 1 };
      function post(u, kind, src) {
        try {
          u = abs(u);
          if (!u || u.length > 4000) { return; }
          var old = posted[u];
          if (old && (srcRank[old.src] || 0) >= (srcRank[src] || 0)) { return; }
          posted[u] = { src: src || '', kind: kind || '' };
          note(u, src);
          window.webkit.messageHandlers.videoSniffer.postMessage({ url: u, kind: kind || '', src: src || '' });
        } catch (e) {}
      }

      // 播放接口常见的路径名：这站把清单挂在 /api/hls/<id> 上，既没后缀、
      // 也不返回清单类型，光看地址只能靠这一段认
      var MEDIA_PATH = /\\/(hls|dash|stream|playlist|manifest|play|vod)(\\/|$)/i;

      // 只凭地址就能认出来的：直链和清单
      function byURL(u) {
        try {
          u = abs(u);
          if (!u) { return; }
          var s = u.split('#')[0];
          var p = s.split('?')[0].toLowerCase();
          if (/\\.(m3u8|mp4|m4v|mov|webm|flv)$/.test(p)) { post(s, '', 'url'); return; }
          if (/\\.mpd$/.test(p)) { post(s, 'DASH', 'url'); return; }
          // 路径里带 m3u8 但没后缀的，多半也是清单
          if (p.indexOf('m3u8') >= 0) { post(s, 'HLS', 'url'); return; }
          if (MEDIA_PATH.test(p)) { post(s, 'HLS', 'url'); }
        } catch (e) {}
      }

      // 从接口文本里挖出来的地址：明显是图片 / 样式 / 脚本的先跳过。
      // 这里不能再「什么链接都上报」——满页的推荐位、站点首页、统计脚本
      // 都会被当成视频，列表里全是点开不对的东西。只认确实像媒体的
      function byText(u) {
        try {
          u = abs(u);
          if (!u) { return; }
          // 同一个接口换个参数就是缩略图 / 预览图，不能当视频收
          if (/[?&](kind|type|format)=(thumbs?|sprite|vtt|images?|poster)/i.test(u)) { return; }
          var s = u.split('#')[0];
          var p = s.split('?')[0].toLowerCase();
          if (/\\.(jpe?g|png|gif|webp|avif|svg|ico|css|js|woff2?|ttf|otf|json|html?|vtt|srt|ass)$/.test(p)) { return; }
          if (p.indexOf('m3u8') >= 0) { post(s, 'HLS', 'text'); return; }
          if (/\\.(mp4|m4v|mov|webm|flv)$/.test(p)) { post(s, '', 'text'); return; }
          if (/\\.mpd$/.test(p)) { post(s, 'DASH', 'text'); return; }
          if (MEDIA_PATH.test(p)) { post(s, 'HLS', 'text'); }
        } catch (e) {}
      }

      function kindOfType(ct) {
        ct = (ct || '').toLowerCase();
        if (ct.indexOf('mpegurl') >= 0) { return 'HLS'; }
        if (ct.indexOf('dash+xml') >= 0) { return 'DASH'; }
        if (ct.indexOf('video/') >= 0) { return 'MEDIA'; }
        return '';
      }

      // 接口返回的 JSON 里常常直接写着播放地址（还可能是转义过的、相对路径的），
      // 只认 Content-Type 会漏掉一大半，这里把整段文本里的媒体链接捞出来
      function scanText(base, text) {
        try {
          if (!text || text.length < 8 || text.length > 600000) { return; }
          var t = text.split('\\\\/').join('/')
            .replace(/\\\\u002f/gi, '/')
            .replace(/\\\\u003a/gi, ':')
            .replace(/&amp;/g, '&');
          var hits = 0;
          var re = /https?:\\/\\/[^\\s"'<>\\\\]+/g;
          var m;
          while ((m = re.exec(t)) !== null && hits < 32) {
            byText(m[0]);
            hits++;
          }
          var rel = /["'](\\/[^"'\\s<>\\\\]{2,300}?(?:m3u8|\\.mp4|\\.mpd|\\.m4v|\\.flv)(?:\\?[^"']*)?)["']/gi;
          while ((m = rel.exec(t)) !== null && hits < 48) {
            try { byText(new URL(m[1], base).href); } catch (e) {}
            hits++;
          }
          scanJSON(base, t);
        } catch (e) {}
      }

      // 不少接口的字段就叫 videoUrl / playUrl / hls，值里的地址没有 .m3u8 后缀，
      // 甚至只是相对路径。这类只靠「像链接」判断不出来，得看字段名
      function scanJSON(base, text) {
        try {
          if (!text || text.length > 600000) { return; }
          var re = /"([A-Za-z0-9_\\-]{2,28})"\\s*:\\s*"([^"\\\\]{6,600})"/g;
          var m, n = 0;
          while ((m = re.exec(text)) !== null && n < 24) {
            var k = m[1].toLowerCase();
            if (!/(url|src|play|video|hls|stream|manifest|m3u8|file|path|link)/.test(k)) { continue; }
            var v = m[2].split('\\\\/').join('/')
              .replace(/\\\\u002f/gi, '/')
              .replace(/\\\\u003a/gi, ':');
            if (/^(blob|data|javascript|about):/i.test(v)) { continue; }
            if (v.charAt(0) !== '/' && !/^https?:/i.test(v)) { continue; }
            try { byText(new URL(v, base).href); } catch (e) {}
            n++;
          }
        } catch (e) {}
      }

      // 有的站点把播放地址藏在没后缀的接口里，只能看返回头或前几十个字节
      function inspect(u, ct, text) {
        try {
          if (text) { scanText(u, text); }
          var kind = kindOfType(ct);
          if (kind === 'HLS' || kind === 'DASH') { post(u, kind, 'type'); return; }
          if (kind === 'MEDIA') { post(u, '', 'type'); return; }
          if (text && text.length > 8) {
            var head = text.slice(0, 64);
            if (head.indexOf('#EXTM3U') >= 0) { post(u, 'HLS', 'type'); return; }
            if (head.indexOf('<MPD') >= 0) { post(u, 'DASH', 'type'); }
          }
        } catch (e) {}
      }

      // 能塞进 video 的 http 地址就是媒体地址：有些站点用原生 HLS，
      // 清单地址没有后缀，只靠 byURL 会漏掉，这里按「正在播」兜底
      function byElement(el) {
        try {
          var host = el.tagName === 'SOURCE' ? el.parentElement : el;
          byElementValue(el.currentSrc || el.src || el.getAttribute('data-src') || '', host);
        } catch (e) {}
      }

      function byElementValue(raw, el) {
        try {
          var u = raw;
          if (!u || typeof u !== 'string') { return; }
          if (/^blob:/i.test(u)) { return; }
          if (!/^https?:/i.test(u)) { return; }
          // 播放器真的在用这个地址，可信度最高：不再做 HEAD 校验，直接收
          if (/\\.(m3u8|mp4|m4v|mov|webm|flv|mpd)(\\?|#|$)/i.test(u)) { post(u, '', 'element'); return; }
          // 没后缀的播放接口（/api/hls/xxx 这种）也是清单，别等它返回 #EXTM3U
          if (MEDIA_PATH.test(u.split('?')[0])) { post(u, 'HLS', 'element'); return; }
          var host = el || {};
          if (host.readyState > 0 || host.videoWidth > 0) { post(u, '', 'element'); }
        } catch (e) {}
      }

      // 有些播放器把地址赋给 src 后很快换掉，2 秒轮询可能一次都扫不到；
      // 这里直接盯住 src 的 setter，赋值 1.5 秒后确认还在播就收
      try {
        var srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (srcDesc && srcDesc.set) {
          Object.defineProperty(HTMLMediaElement.prototype, 'src', {
            configurable: true,
            enumerable: srcDesc.enumerable,
            get: srcDesc.get,
            set: function(value) {
              try {
                var el = this;
                setTimeout(function() { byElementValue(value, el); }, 1500);
              } catch (e) {}
              return srcDesc.set.call(this, value);
            }
          });
        }
      } catch (e) {}

      function scanShadow(root) {
        try {
          var all = root.querySelectorAll('*');
          for (var i = 0; i < all.length; i++) {
            var host = all[i];
            if (!host.shadowRoot) { continue; }
            var vids = host.shadowRoot.querySelectorAll('video, source');
            for (var j = 0; j < vids.length; j++) {
              byElement(vids[j]);
            }
            scanShadow(host.shadowRoot);
          }
        } catch (e) {}
      }

      function scan() {
        try {
          var nodes = document.querySelectorAll('video, source');
          for (var i = 0; i < nodes.length; i++) {
            byElement(nodes[i]);
          }
          // 自绘播放器可能把 video 关在 shadow DOM 里，document 查不到
          if (nodes.length === 0) { scanShadow(document); }
        } catch (e) {}
        scanInlineScripts();
        scanImages();
      }

      // SSR 会把首屏数据直接内联在 script 里，播放地址可能就在其中
      var inlineScanned = false;
      function scanInlineScripts() {
        if (inlineScanned) { return; }
        inlineScanned = true;
        try {
          var list = document.querySelectorAll('script:not([src])');
          for (var i = 0; i < list.length && i < 60; i++) {
            var t = list[i].textContent || '';
            if (t.length > 16 && t.length < 400000) { scanText(location.href, t); }
          }
        } catch (e) {}
      }

      var sentImages = {};

      function sendImage(u, w, h) {
        try {
          u = abs(u);
          if (!u || u.length > 2000) { return; }
          if (sentImages[u]) { return; }
          sentImages[u] = 1;
          window.webkit.messageHandlers.imageSniffer.postMessage({ url: u, width: w || 0, height: h || 0 });
        } catch (e) {}
      }

      function attr(el, name) {
        try { return el.getAttribute(name) || ''; } catch (e) { return ''; }
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

      // 同一张图可能同时有占位图、懒加载地址、srcset、原图属性，按优先级挑真的那个
      function pickImage(el) {
        var list = [];
        try {
          list.push(bestFromSrcset(el));
          list.push(el.currentSrc);
          list.push(el.src);
          var attrs = ['data-src', 'data-original', 'data-lazy-src', 'data-url',
                       'data-echo', 'data-actualsrc', 'data-lazyload'];
          for (var i = 0; i < attrs.length; i++) { list.push(attr(el, attrs[i])); }
          var pic = el.parentElement;
          if (pic && pic.tagName === 'PICTURE') {
            var srcs = pic.querySelectorAll('source');
            for (var j = 0; j < srcs.length; j++) {
              list.push(bestFromSrcset(srcs[j]));
              list.push(attr(srcs[j], 'src'));
            }
          }
        } catch (e) {}
        for (var k = 0; k < list.length; k++) {
          var a = abs(list[k]);
          if (a) { return a; }
        }
        return '';
      }

      function scanImages() {
        try {
          var imgs = document.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            var el = imgs[i];
            var w = el.naturalWidth || 0;
            var h = el.naturalHeight || 0;
            var u = pickImage(el);
            if (!u) { continue; }
            var bigger = attr(el, 'data-src') || attr(el, 'data-original') || attr(el, 'data-lazy-src');
            // 已知尺寸特别小的多半是图标 / 表情；挂着原图地址的另算
            if (w && h && (w < 140 || h < 140) && !bigger) { continue; }
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

          // 背景图 / 懒加载占位
          var bgs = document.querySelectorAll('[style*="background-image"], [data-bg], [data-background-image]');
          var limit = Math.min(bgs.length, 300);
          for (var b = 0; b < limit; b++) {
            var node = bgs[b];
            var raw = attr(node, 'data-bg') || attr(node, 'data-background-image');
            if (!raw) {
              var bg = '';
              try { bg = node.style.backgroundImage || ''; } catch (e) {}
              var mm = bg.match(/url\\(["']?(.*?)["']?\\)/);
              raw = mm ? mm[1] : '';
            }
            if (!raw) { continue; }
            var cw = node.clientWidth || 0;
            var ch = node.clientHeight || 0;
            if (cw && ch && (cw < 160 || ch < 160)) { continue; }
            sendImage(raw, cw, ch);
          }
        } catch (e) {}
      }

      window.__vlScan = scan;
      window.__vlScanImages = scanImages;
      scan();
      setInterval(scan, 2000);

      // 往下滑才加载的图，滑完立刻补一遍；只认 http(s)，不会冒出一堆 base64
      var scrollTimer = null;
      window.addEventListener('scroll', function() {
        if (scrollTimer) { return; }
        scrollTimer = setTimeout(function() { scrollTimer = null; scanImages(); }, 500);
      }, true);
      window.addEventListener('resize', function() { scanImages(); });

      try {
        new MutationObserver(scan).observe(document.documentElement, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src', 'srcset', 'data-src', 'data-original', 'style']
        });
      } catch (e) {}

      // 有的站把播放地址 base64 混淆后放进接口，页面自己解密再交给播放器。
      // 这类地址既不产生可识别的请求、也不进 DOM，只能盯住解密过程。
      // 一般的套路是 atob 完再做一次整体位移，最后 JSON.parse 出明文
      function mostlyPrintable(s) {
        try {
          var n = Math.min(s.length, 200), ok = 0;
          for (var i = 0; i < n; i++) {
            var c = s.charCodeAt(i);
            if (c >= 32 && c < 127) { ok++; }
          }
          return n > 0 && ok / n > 0.6;
        } catch (e) { return false; }
      }

      function tryShifted(s) {
        try {
          if (!s || s.length < 24 || s.length > 300000 || !mostlyPrintable(s)) { return; }
          if (s.indexOf('http') >= 0 || s.indexOf('{') >= 0) { return; }
          for (var k = 1; k <= 64; k++) {
            var head = '';
            for (var i = 0; i < Math.min(24, s.length); i++) {
              head += String.fromCharCode(s.charCodeAt(i) - k);
            }
            if (head.indexOf('{') < 0 && head.indexOf('http') < 0) { continue; }
            var out = '';
            for (var j = 0; j < s.length; j++) { out += String.fromCharCode(s.charCodeAt(j) - k); }
            if (out.indexOf('http') >= 0 || out.indexOf('m3u8') >= 0 || out.indexOf('hls') >= 0) {
              scanText(location.href, out);
            }
            return;
          }
        } catch (e) {}
      }

      try {
        var origAtob = window.atob;
        if (origAtob) {
          var seenAtob = {};
          window.atob = function(s) {
            var out = origAtob.apply(window, arguments);
            try {
              if (typeof out === 'string' && out.length > 16 && out.length < 300000) {
                var key = out.slice(0, 64);
                if (!seenAtob[key]) {
                  seenAtob[key] = 1;
                  if (out.indexOf('http') >= 0 || out.indexOf('hls') >= 0 || out.indexOf('{') >= 0) {
                    scanText(location.href, out);
                  }
                  tryShifted(out);
                }
              }
            } catch (e) {}
            return out;
          };
        }
      } catch (e) {}

      // 解密后一般会 JSON.parse 一次，这里拿到的是明文，比猜编码可靠得多
      try {
        var origParse = JSON.parse;
        if (origParse) {
          JSON.parse = function(text, reviver) {
            try {
              if (typeof text === 'string' && text.length > 16 && text.length < 400000
                  && (text.indexOf('http') >= 0 || text.indexOf('Url') >= 0 || text.indexOf('hls') >= 0)) {
                scanText(location.href, text);
              }
            } catch (e) {}
            return origParse.apply(JSON, arguments);
          };
        }
      } catch (e) {}

      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function(input, init) {
          var asked = '';
          try { asked = typeof input === 'string' ? input : (input && input.url) || ''; } catch (e) {}
          note(asked, 'fetch');
          byURL(asked);
          var promise = origFetch.apply(this, arguments);
          try {
            promise.then(function(res) {
              try {
                var finalURL = (res && res.url) || asked;
                note(finalURL, 'fetch');
                byURL(finalURL);
                var ct = (res.headers && res.headers.get('content-type')) || '';
                if (kindOfType(ct)) { inspect(finalURL, ct, ''); return; }
                // 接口返回的 JSON 里可能就写着播放地址；文本类响应才读，
                // 视频本体一律不碰，避免把几百兆读进内存
                var texty = /json|text\\/plain|text\\/html|xml/i.test(ct);
                var len = parseInt((res.headers && res.headers.get('content-length')) || '0', 10);
                if (texty && (!len || len < 1048576)) {
                  res.clone().text().then(function(t) {
                    if (t && t.length < 1048576) { inspect(finalURL, ct, t); }
                  }).catch(function() {});
                } else if (len && len < 262144) {
                  res.clone().text().then(function(t) { inspect(finalURL, ct, t); }).catch(function() {});
                }
              } catch (e) {}
            }).catch(function() {});
          } catch (e) {}
          return promise;
        };
      }

      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        try {
          this.__vlURL = typeof url === 'string' ? url : '';
          note(this.__vlURL, 'xhr');
          byURL(this.__vlURL);
        } catch (e) {}
        return origOpen.apply(this, arguments);
      };

      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function() {
        var xhr = this;
        try {
          xhr.addEventListener('load', function() {
            try {
              var u = xhr.responseURL || xhr.__vlURL || '';
              note(u, 'xhr');
              byURL(u);
              var ct = '';
              try { ct = xhr.getResponseHeader('content-type') || ''; } catch (e) {}
              if (kindOfType(ct)) { inspect(u, ct, ''); return; }
              var type = xhr.responseType;
              if ((type === '' || type === 'text') && typeof xhr.responseText === 'string') {
                var text = xhr.responseText;
                if (text.length < 1048576 && /json|text\\/|xml/i.test(ct)) { inspect(u, ct, text); }
              } else if (type === 'json' && xhr.response) {
                try { inspect(u, ct, JSON.stringify(xhr.response)); } catch (e) {}
              } else if (type === 'arraybuffer') {
                // hls.js / shaka 取清单常走 arraybuffer，类型头又给个 octet-stream，
                // 只能自己看开头几个字节
                try {
                  var buf = xhr.response;
                  if (buf && buf.byteLength > 8 && buf.byteLength < 262144) {
                    var head = new Uint8Array(buf, 0, Math.min(80, buf.byteLength));
                    var txt = '';
                    for (var i = 0; i < head.length; i++) { txt += String.fromCharCode(head[i]); }
                    if (txt.indexOf('#EXTM3U') >= 0) { post(u, 'HLS', 'type'); return; }
                    if (txt.indexOf('<MPD') >= 0) { post(u, 'DASH', 'type'); return; }
                  }
                } catch (e) {}
              }
            } catch (e) {}
          });
        } catch (e) {}
        return origSend.apply(this, arguments);
      };

      // 定时扫一遍已经发出去的请求，worker 里发的也能捞回来
      setInterval(function() {
        try {
          var list = performance.getEntriesByType('resource');
          for (var i = 0; i < list.length; i++) {
            note(list[i].name, 'net');
            byURL(list[i].name);
          }
        } catch (e) {}
      }, 3000);
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

    /// 选中文字后在选区下方浮一个「存备忘」，点一下把这段字连同出处交给原生。
    /// 按钮放在选区下方是为了躲开系统划词菜单；点它时选区会被收起，
    /// 所以 touchstart 先把文字抓在手里，不能等 touchend 再读。
    static let memoPick = """
    (function() {
      if (window.__vlMemoPick) { return; }
      window.__vlMemoPick = true;

      var btn = null;
      var timer = null;
      var held = '';

      function remove() {
        if (btn && btn.parentNode) { btn.parentNode.removeChild(btn); }
        btn = null;
      }

      function currentText() {
        var sel = window.getSelection();
        return sel ? sel.toString().trim() : '';
      }

      function send() {
        var text = (held || currentText()).trim();
        held = '';
        if (!text) { return; }
        try {
          window.webkit.messageHandlers.memoPick.postMessage({
            text: text,
            url: location.href,
            title: document.title || ''
          });
        } catch (e) {}
        remove();
        var sel = window.getSelection();
        if (sel) { try { sel.removeAllRanges(); } catch (e) {} }
      }

      function ensure() {
        if (btn) { return btn; }
        btn = document.createElement('div');
        btn.setAttribute('id', '__vl_memo_pick');
        btn.textContent = '存备忘';
        btn.style.cssText = [
          'all:initial',
          'position:fixed',
          'display:block',
          'z-index:2147483647',
          'padding:7px 13px',
          'border:0',
          'border-radius:16px',
          'background:rgba(28,30,36,0.94)',
          'color:#ffffff',
          'font:600 13px -apple-system,system-ui,sans-serif',
          'line-height:1',
          'white-space:nowrap',
          'box-shadow:0 6px 18px rgba(0,0,0,0.28)',
          'cursor:pointer',
          'user-select:none',
          '-webkit-user-select:none',
          '-webkit-touch-callout:none',
          'touch-action:manipulation'
        ].join(';');

        btn.addEventListener('touchstart', function(e) {
          held = currentText();
          e.stopPropagation();
        }, { passive: true });

        btn.addEventListener('touchend', function(e) {
          e.preventDefault();
          e.stopPropagation();
          send();
        }, { passive: false });

        btn.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          send();
        });

        (document.body || document.documentElement).appendChild(btn);
        return btn;
      }

      function place() {
        var sel = window.getSelection();
        if (!sel || sel.isCollapsed || sel.rangeCount === 0) { return false; }
        var text = sel.toString().trim();
        if (text.length < 2) { return false; }

        var active = document.activeElement;
        if (active) {
          var tag = (active.tagName || '').toUpperCase();
          if (tag === 'INPUT' || tag === 'TEXTAREA' || active.isContentEditable) { return false; }
        }

        var range = sel.getRangeAt(0);
        var rect = range.getBoundingClientRect();
        if (!rect || (rect.width === 0 && rect.height === 0)) { return false; }

        var el = ensure();
        var top = rect.bottom + 10;
        if (top + 36 > window.innerHeight) { top = Math.max(8, rect.top - 44); }
        var left = rect.left + rect.width / 2 - 32;
        left = Math.max(10, Math.min(left, window.innerWidth - 86));
        el.style.top = Math.round(top) + 'px';
        el.style.left = Math.round(left) + 'px';
        return true;
      }

      function refresh() {
        clearTimeout(timer);
        timer = setTimeout(function() {
          if (place()) { return; }
          // 点浮层时系统会先收起选区，晚一点再撤按钮，别把点击吃掉
          clearTimeout(timer);
          timer = setTimeout(function() {
            if (currentText().length < 2) { remove(); }
          }, 320);
        }, 140);
      }

      document.addEventListener('selectionchange', refresh, true);
      document.addEventListener('scroll', function() { remove(); }, true);
      window.addEventListener('resize', function() { remove(); });
    })();
    """

    static let readerRun = "window.__vlReader ? window.__vlReader() : false"

    /// 自动滚动收集：懒加载的图集 / 长页面，一行一行往下推，
    /// 每滚一屏就把已经加载出来的图扫一遍，到底后等两次加载再收网。
    /// 参数 stop 为 true 时只负责停下。
    static let autoScroll = """
    window.__vlAutoScroll = function(stop) {
      try {
        if (window.__vlScrollTimer) {
          clearInterval(window.__vlScrollTimer);
          window.__vlScrollTimer = null;
        }
        if (stop || window.__vlScrolling) {
          window.__vlScrolling = false;
          window.__vlToast && window.__vlToast('已停止滚动');
          return false;
        }

        var still = 0;          // 连续贴底且页面没变长的次数
        var lastHeight = 0;
        var ticks = 0;
        window.__vlScrolling = true;

        function height() {
          return Math.max(
            document.body ? document.body.scrollHeight : 0,
            document.documentElement ? document.documentElement.scrollHeight : 0
          );
        }

        window.__vlScrollTimer = setInterval(function() {
          ticks++;
          var h = height();
          var vh = window.innerHeight || 600;
          var y = window.scrollY || window.pageYOffset || 0;

          // 页面又长高了，说明懒加载还在吐内容，重新计数
          if (h > lastHeight + 40) {
            lastHeight = h;
            still = 0;
          }

          var atBottom = (y + vh) >= (h - 100);
          window.scrollBy(0, Math.round(vh * (atBottom ? 0.5 : 0.8)));

          if (window.__vlScan) { window.__vlScan(); }

          if (atBottom) {
            still++;
            // 到底之后再多等三秒，给图片留加载时间
            if (still >= 6) {
              clearInterval(window.__vlScrollTimer);
              window.__vlScrollTimer = null;
              window.__vlScrolling = false;
              window.__vlScan && window.__vlScan();
              var n = document.images ? document.images.length : 0;
              window.__vlToast && window.__vlToast('已经滚到底，页面里共有 ' + n + ' 张图');
              return;
            }
          } else {
            still = 0;
          }

          // 兜底：最多滚 4 分钟，别在无限滚动的站点上停不下来
          if (ticks >= 440) {
            clearInterval(window.__vlScrollTimer);
            window.__vlScrollTimer = null;
            window.__vlScrolling = false;
            window.__vlToast && window.__vlToast('滚动时间到，先收了这些');
          }
        }, 550);

        window.__vlToast && window.__vlToast('正在向下滚动收集，再点一次可停');
        return true;
      } catch (e) { return false; }
    };
    """

    /// 脚本镜像站：这些站点一律按浅色渲染，避免跟随系统深色变黑
    static func isLightSite(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        if h == "greasyfork.icu" || h.hasSuffix(".greasyfork.icu") { return true }
        if h == "greasyfork.org" || h.hasSuffix(".greasyfork.org") { return true }
        if h == "greasyfork.org.cn" || h.hasSuffix(".greasyfork.org.cn") { return true }
        return false
    }

    /// 清爽模式：把挡在正文上的固定浮层摘掉，并把被锁住的滚动还原
    static let cleanPage = """
    (function() {
      try {
        if (window.__vlCleanDone) { return; }
        window.__vlCleanDone = true;

        var vw = window.innerWidth || 0, vh = window.innerHeight || 0;
        var badName = /(^|[-_])(mask|modal|overlay|popup|dialog|guide|advert|ads?|banner|float|toast)([-_]|$)/i;
        var goodName = /(player|video|jwplayer|dplayer|artplayer|shaka|hls)/i;

        function box(el) {
          var r = el.getBoundingClientRect();
          return r.width * r.height;
        }

        var nodes = document.querySelectorAll('body *');
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (!(el instanceof HTMLElement)) { continue; }
          if (el.tagName === 'VIDEO' || el.querySelector('video,audio')) { continue; }

          var cs = window.getComputedStyle(el);
          if (cs.position !== 'fixed' && cs.position !== 'sticky') { continue; }

          var name = (el.className || '') + ' ' + (el.id || '');
          if (goodName.test(name)) { continue; }

          var z = parseInt(cs.zIndex, 10) || 0;
          var big = box(el) > vw * vh * 0.22;
          if (big && (badName.test(name) || z >= 90)) { el.remove(); }
        }

        if (!document.getElementById('__vl_clean_style')) {
          var style = document.createElement('style');
          style.id = '__vl_clean_style';
          style.textContent = 'html,body{overflow:auto !important;position:static !important;touch-action:auto !important;}';
          document.documentElement.appendChild(style);
        }
      } catch (e) {}
    })();
    """

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

        // 浮层只挂主文档，iframe 里选字也走主文档的通知，避免每个小窗都冒一个
        controller.addUserScript(
            WKUserScript(source: memoPick, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

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
