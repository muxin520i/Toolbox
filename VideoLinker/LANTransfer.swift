import Foundation
import Network
import UIKit
import Combine

// MARK: - 局域网双向互传
//
// 接收端沿用 LANInbox 的 HTTP 服务（PUT /upload），
// 这里补上「被发现」和「发出去」两件事：
//   · LANInbox 启动时把 ip / port 写进 Bonjour TXT，另一台手机能直接看到
//   · 本页用 NWBrowser 浏览同一服务类型，选设备后按文件流式 PUT 过去

final class LANTransfer: NSObject, ObservableObject {

    static let shared = LANTransfer()

    struct Peer: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: Int
    }

    struct Job: Identifiable {
        enum State {
            case waiting, sending, done, failed
        }

        let id = UUID()
        let fileName: String
        let peerName: String
        var progress: Double = 0
        var state: State = .waiting
        var detail = ""
    }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var browsing = false
    @Published private(set) var errorText = ""

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.example.VideoLinker.lantransfer")
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 4
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var jobForTask: [Int: UUID] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
    }

    // MARK: 浏览

    func startBrowsing() {
        guard browser == nil else { return }

        LocalNetworkPermission.probe { _ in }

        let params = NWParameters.tcp
        // 只走同一 Wi-Fi，不开 AWDL：点对点会让设备列表里冒出隔空投送那种远距离设备
        params.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjour(type: LocalNetworkPermission.serviceType, domain: nil),
            using: params
        )

        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.browsing = true
                    self.errorText = ""
                case .failed(let error):
                    self.browsing = false
                    self.errorText = "搜索设备失败：\(error.localizedDescription)"
                case .waiting(let error):
                    self.browsing = false
                    if LocalNetworkPermission.isPolicyDenied(error) {
                        self.errorText = "本地网络权限被关了，去「设置 → 工具箱 → 本地网络」打开"
                    }
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            var list: [Peer] = []
            // 自己也在广播，别把自己列出来
            let myAddress = LANInbox.wifiAddress()

            for result in results {
                guard case let .bonjour(txt) = result.metadata else { continue }
                guard case let .string(host)? = txt.getEntry(for: "ip"), !host.isEmpty,
                      host != myAddress,
                      case let .string(portText)? = txt.getEntry(for: "port"),
                      let port = Int(portText) else { continue }
                guard case let .service(name, _, _, _) = result.endpoint else { continue }

                let peer = Peer(
                    id: "\(name)@\(host):\(port)",
                    name: name,
                    host: host,
                    port: port
                )
                if !list.contains(where: { $0.id == peer.id }) {
                    list.append(peer)
                }
            }

            list.sort { $0.name < $1.name }
            DispatchQueue.main.async { self.peers = list }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        browsing = false
        peers = []
    }

    // MARK: 发送

    func send(urls: [URL], to peer: Peer) {
        guard !urls.isEmpty else { return }

        for url in urls {
            var job = Job(fileName: url.lastPathComponent, peerName: peer.name)
            job.state = .sending
            job.detail = "0%"
            jobs.insert(job, at: 0)
            upload(url: url, to: peer, jobID: job.id)
        }
    }

    private func upload(url: URL, to peer: Peer, jobID: UUID) {
        let name = url.lastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let endpoint = URL(string: "http://\(peer.host):\(peer.port)/upload?name=\(encoded)") else {
            finish(jobID, state: .failed, detail: "地址拼不出来")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 60

        let task = session.uploadTask(with: request, fromFile: url)
        task.taskDescription = jobID.uuidString

        lock.lock()
        jobForTask[task.taskIdentifier] = jobID
        lock.unlock()

        task.resume()
    }

    private func jobID(for task: URLSessionTask) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return jobForTask[task.taskIdentifier]
    }

    private func update(_ jobID: UUID, progress: Double? = nil, detail: String? = nil) {
        DispatchQueue.main.async {
            guard let index = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
            if let progress = progress {
                self.jobs[index].progress = progress
            }
            if let detail = detail {
                self.jobs[index].detail = detail
            }
        }
    }

    private func finish(_ jobID: UUID, state: Job.State, detail: String) {
        DispatchQueue.main.async {
            guard let index = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
            self.jobs[index].state = state
            self.jobs[index].detail = detail
            if state == .done { self.jobs[index].progress = 1 }
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed }
    }
}

// MARK: - URLSession

extension LANTransfer: URLSessionTaskDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let jobID = jobID(for: task), totalBytesExpectedToSend > 0 else { return }
        let ratio = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        update(jobID, progress: ratio, detail: "\(Int(ratio * 100))%")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let jobID = jobID(for: task) else { return }

        lock.lock()
        jobForTask.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        if let error = error {
            finish(jobID, state: .failed, detail: error.localizedDescription)
            return
        }

        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 || code == 201 || code == 204 {
            finish(jobID, state: .done, detail: "已送达")
        } else {
            finish(jobID, state: .failed, detail: "对方返回 \(code)")
        }
    }
}
