import Foundation
import Network
import SwiftUI
import UIKit

// MARK: - 局域网收件箱
//
// 手机在同一个 Wi-Fi 下开一个极简的 HTTP 服务：
//   GET /                 → 一个拖拽上传页面
//   PUT /upload?name=xxx  → 请求体直接落盘成文件
// 电脑浏览器打开 http://手机IP:端口，把视频拖进去，就进「下载」列表了。
// 只处理这两个路由，不做多部分表单解析，body 原样写文件，简单且不会一次吃进内存。

final class LANInbox: ObservableObject {
    static let shared = LANInbox()

    @Published private(set) var running = false
    @Published private(set) var address = ""
    @Published private(set) var errorText = ""
    @Published private(set) var receivedCount = 0
    @Published private(set) var lastReceived = ""

    /// 端口占用时按顺序往后试
    private let candidatePorts: [UInt16] = [8080, 8081, 8082, 8090, 8099]
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private let queue = DispatchQueue(label: "com.example.VideoLinker.laninbox")
    private var portIndex = 0

    private init() {}

    // MARK: 开关

    func start() {
        guard listener == nil else { return }
        errorText = ""
        guard Self.wifiAddress() != nil else {
            errorText = "先连上 Wi-Fi，要和电脑在同一个网络里"
            running = false
            return
        }
        portIndex = 0
        // 收件箱同样要本地网络权限，而纯监听端口系统不会弹窗，这里顺手触发一次
        LocalNetworkPermission.probe { _ in }
        queue.async { [weak self] in self?.listen(at: 0) }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            for (_, client) in self.clients {
                client.finishWriting()
                client.connection.cancel()
            }
            self.clients.removeAll()
        }
        running = false
        address = ""
    }

    func toggle() {
        running ? stop() : start()
    }

    // MARK: 监听

    private func listen(at index: Int) {
        guard index < candidatePorts.count else {
            DispatchQueue.main.async {
                self.running = false
                self.errorText = "端口都被占用了，断开 Wi-Fi 重连或者重启 App 再试"
            }
            return
        }

        let port = candidatePorts[index]
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: endpoint)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.portIndex = index
                    let ip = Self.wifiAddress() ?? "127.0.0.1"
                    DispatchQueue.main.async {
                        self.address = "http://\(ip):\(port)"
                        self.running = true
                        self.errorText = ""
                    }
                case .failed:
                    listener.cancel()
                    self.listener = nil
                    self.listen(at: index + 1)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listen(at: index + 1)
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let client = Client(connection: connection)
        clients[key] = client

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(key) }
        }
        connection.start(queue: queue)
        receive(client, key: key)
    }

    private func receive(_ client: Client, key: ObjectIdentifier) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.consume(client, data, key: key)
            }
            if error != nil || isComplete {
                self.close(key)
                return
            }
            if self.clients[key] != nil {
                self.receive(client, key: key)
            }
        }
    }

    /// 先攒请求头，解析完再决定是回页面还是往文件里写
    private func consume(_ client: Client, _ data: Data, key: ObjectIdentifier) {
        var buffer = data

        if !client.headDone {
            client.header.append(data)
            guard let mark = client.header.range(of: Data("\r\n\r\n".utf8)) else {
                if client.header.count > 32 * 1024 {
                    respond(client, status: "431 Request Header Fields Too Large", body: Data(), type: "text/plain", key: key)
                }
                return
            }

            let head = client.header.subdata(in: 0..<mark.lowerBound)
            let rest = client.header.subdata(in: mark.upperBound..<client.header.count)
            client.header = Data()
            client.headDone = true

            guard parse(head: head, client: client, key: key) else { return }
            buffer = rest

            if client.bodyLeft == 0 {
                complete(client, key: key)
                return
            }
        }

        guard client.bodyLeft > 0 else { return }
        let take = min(Int64(buffer.count), client.bodyLeft)
        if take > 0 {
            let chunk = buffer.prefix(Int(take))
            client.write(chunk)
            client.bodyLeft -= take
        }
        if client.bodyLeft == 0 {
            complete(client, key: key)
        }
    }

    /// 返回 true 表示后面还有请求体要收
    private func parse(head: Data, client: Client, key: ObjectIdentifier) -> Bool {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return false }

        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return false }
        let method = parts[0].uppercased()
        let target = parts[1]

        var contentLength: Int64 = 0
        for line in lines.dropFirst() {
            let pair = line.components(separatedBy: ":")
            guard pair.count >= 2 else { continue }
            if pair[0].lowercased() == "content-length" {
                contentLength = Int64(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        if method == "GET" || method == "HEAD" {
            if target == "/" || target.hasPrefix("/?") {
                let body = Data(Self.page.utf8)
                respond(client, status: "200 OK", body: method == "HEAD" ? Data() : body,
                        type: "text/html; charset=utf-8", key: key)
            } else {
                respond(client, status: "204 No Content", body: Data(), type: "text/plain", key: key)
            }
            return false
        }

        guard method == "PUT", target.hasPrefix("/upload") else {
            respond(client, status: "404 Not Found", body: Data("not found".utf8), type: "text/plain", key: key)
            return false
        }

        guard contentLength > 0, contentLength < 8 * 1024 * 1024 * 1024 else {
            respond(client, status: "400 Bad Request", body: Data("bad length".utf8), type: "text/plain", key: key)
            return false
        }

        let name = Self.fileName(from: target)
        let dest = DownloadManager.unique(in: DownloadManager.directory(), name: name)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dest) else {
            respond(client, status: "500 Internal Server Error", body: Data("cannot save".utf8), type: "text/plain", key: key)
            return false
        }

        client.fileURL = dest
        client.fileHandle = handle
        client.bodyLeft = contentLength
        return true
    }

    private func complete(_ client: Client, key: ObjectIdentifier) {
        client.finishWriting()
        let name = client.fileURL?.lastPathComponent ?? ""

        if let url = client.fileURL {
            DispatchQueue.main.async {
                DownloadManager.shared.importFile(at: url)
                self.receivedCount += 1
                self.lastReceived = url.lastPathComponent
            }
        }

        let payload = "{\"ok\":true,\"name\":\"\(name)\"}".data(using: .utf8) ?? Data()
        respond(client, status: "200 OK", body: payload, type: "application/json; charset=utf-8", key: key)
    }

    private func respond(_ client: Client, status: String, body: Data, type: String, key: ObjectIdentifier) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)

        client.connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            client.connection.cancel()
            self?.close(key)
        })
    }

    private func close(_ key: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: key) else { return }
        client.finishWriting()
        client.connection.cancel()
    }

    // MARK: 小工具

    /// 取 Wi-Fi（en0）的 IPv4 地址
    static func wifiAddress() -> String? {
        var result: String?
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: interface.ifa_name) == "en0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let size = socklen_t(addr.pointee.sa_len)
            if getnameinfo(addr, size, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
            }
        }
        return result
    }

    /// 从 /upload?name=xxx 里取文件名，顺手把路径和怪字符挡掉
    static func fileName(from target: String) -> String {
        var raw = target
        if let range = raw.range(of: "name=") {
            raw = String(raw[range.upperBound...])
            if let amp = raw.firstIndex(of: "&") { raw = String(raw[..<amp]) }
            raw = raw.removingPercentEncoding ?? raw
        } else {
            raw = "upload-\(Int(Date().timeIntervalSince1970)).bin"
        }

        raw = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = "upload.bin" }
        if raw.count > 100 {
            let ext = (raw as NSString).pathExtension
            let base = (raw as NSString).deletingPathExtension
            raw = String(base.prefix(90)) + (ext.isEmpty ? "" : "." + ext)
        }
        return raw
    }

    // MARK: 一条连接

    private final class Client {
        let connection: NWConnection
        var header = Data()
        var headDone = false
        var bodyLeft: Int64 = 0
        var fileHandle: FileHandle?
        var fileURL: URL?

        init(connection: NWConnection) {
            self.connection = connection
        }

        func write(_ data: Data) {
            guard let handle = fileHandle else { return }
            try? handle.write(contentsOf: data)
        }

        func finishWriting() {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}

// MARK: - 上传页面

extension LANInbox {
    static let page = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>传到 VideoLinker</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; flex-direction:column; align-items:center;
         font-family:-apple-system,system-ui,"PingFang SC","Microsoft YaHei",sans-serif;
         background:#f5f5f7; color:#1d1d1f; padding:40px 20px; }
  h1 { font-size:22px; margin:0 0 6px; }
  .sub { color:#6e6e73; font-size:14px; margin:0 0 26px; text-align:center; line-height:1.6; }
  #drop { width:min(620px,100%); border:2px dashed #c7c7cc; border-radius:16px; background:#fff;
          padding:56px 24px; text-align:center; transition:.18s; cursor:pointer; }
  #drop.over { border-color:#0a84ff; background:#f0f7ff; transform:scale(1.01); }
  #drop p { margin:10px 0 0; color:#8e8e93; font-size:14px; }
  button { border:0; border-radius:10px; background:#0a84ff; color:#fff; font-size:15px;
           padding:12px 22px; cursor:pointer; font-weight:600; }
  button:active { opacity:.85; }
  ul { list-style:none; width:min(620px,100%); padding:0; margin:26px 0 0; }
  li { background:#fff; border-radius:12px; padding:12px 16px; margin-bottom:10px; }
  .row { display:flex; justify-content:space-between; gap:12px; font-size:13px; margin-bottom:8px; }
  .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .pct { color:#8e8e93; flex:none; font-variant-numeric:tabular-nums; }
  .bar { height:6px; border-radius:3px; background:#ececf0; overflow:hidden; }
  .bar i { display:block; height:100%; width:0; background:#0a84ff; transition:width .2s; }
  li.ok .bar i { background:#34c759; }
  li.ok .pct { color:#34c759; }
  li.bad .bar i { background:#ff3b30; }
  li.bad .pct { color:#ff3b30; }
  .tip { color:#8e8e93; font-size:12px; margin-top:28px; text-align:center; line-height:1.7; }
</style>
</head>
<body>
  <h1>传到 VideoLinker</h1>
  <p class="sub">手机和电脑要连同一个 Wi-Fi，App 留在前台。<br>文件会直接进手机的「下载」列表。</p>

  <div id="drop">
    <button id="pick">选择文件</button>
    <p>或者把视频拖到这里</p>
    <input id="file" type="file" multiple hidden>
  </div>

  <ul id="list"></ul>
  <p class="tip">支持一次拖多个。传大文件时别锁屏，也别切走 App。</p>

<script>
  var drop = document.getElementById('drop');
  var picker = document.getElementById('file');
  var list = document.getElementById('list');
  var pending = [];
  var busy = false;

  document.getElementById('pick').addEventListener('click', function (e) {
    e.stopPropagation();
    picker.click();
  });
  drop.addEventListener('click', function () { picker.click(); });
  picker.addEventListener('change', function () {
    enqueue(Array.prototype.slice.call(picker.files));
    picker.value = '';
  });

  ['dragenter', 'dragover'].forEach(function (t) {
    drop.addEventListener(t, function (e) { e.preventDefault(); drop.classList.add('over'); });
  });
  ['dragleave', 'drop'].forEach(function (t) {
    drop.addEventListener(t, function (e) { e.preventDefault(); drop.classList.remove('over'); });
  });
  drop.addEventListener('drop', function (e) {
    var files = Array.prototype.slice.call(e.dataTransfer.files);
    enqueue(files);
  });

  function enqueue(files) {
    files.forEach(function (f) { pending.push(f); });
    pump();
  }

  function pump() {
    if (busy) { return; }
    var file = pending.shift();
    if (!file) { return; }
    busy = true;
    upload(file, function () { busy = false; pump(); });
  }

  function upload(file, done) {
    var li = document.createElement('li');
    li.innerHTML = '<div class="row"><span class="name"></span><span class="pct">0%</span></div>'
                 + '<div class="bar"><i></i></div>';
    li.querySelector('.name').textContent = file.name;
    list.insertBefore(li, list.firstChild);

    var bar = li.querySelector('i');
    var pct = li.querySelector('.pct');
    var xhr = new XMLHttpRequest();

    xhr.open('PUT', '/upload?name=' + encodeURIComponent(file.name));
    xhr.upload.onprogress = function (e) {
      if (!e.lengthComputable) { return; }
      var p = Math.round(e.loaded / e.total * 100);
      bar.style.width = p + '%';
      pct.textContent = p + '%';
    };
    xhr.onload = function () {
      if (xhr.status === 200) {
        bar.style.width = '100%';
        li.classList.add('ok');
        pct.textContent = '已保存';
      } else {
        li.classList.add('bad');
        pct.textContent = '失败 ' + xhr.status;
      }
      done();
    };
    xhr.onerror = function () {
      li.classList.add('bad');
      pct.textContent = '连接断开';
      done();
    };
    xhr.send(file);
  }
</script>
</body>
</html>
"""#
}

// MARK: - 界面

struct LANInboxView: View {
    @ObservedObject private var inbox = LANInbox.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusCard
                    stepsCard
                    if inbox.receivedCount > 0 { receivedCard }
                    if !inbox.errorText.isEmpty {
                        Text(inbox.errorText)
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("局域网收件箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(inbox.running ? "正在接收" : "未开启")
                        .font(.system(size: 16, weight: .semibold))
                    Text(inbox.running ? "电脑浏览器打开下面的地址" : "开启后手机和电脑要连同一个 Wi-Fi")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { inbox.running },
                    set: { on in on ? inbox.start() : inbox.stop() }
                ))
                .labelsHidden()
            }

            if inbox.running {
                HStack(spacing: 10) {
                    Text(inbox.address)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = inbox.address
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("怎么用")
                .font(.system(size: 14, weight: .semibold))

            step(1, "手机连上 Wi-Fi，打开上面的开关")
            step(2, "电脑浏览器输入 \(inbox.running ? inbox.address : "手机上显示的地址")")
            step(3, "把视频拖进网页，或者点「选择文件」")
            step(4, "传完自动出现在「下载」列表里，可以直接播放、导出")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var receivedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("已经收下 \(inbox.receivedCount) 个文件")
                    .font(.system(size: 13, weight: .medium))
                if !inbox.lastReceived.isEmpty {
                    Text("最近：\(inbox.lastReceived)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
