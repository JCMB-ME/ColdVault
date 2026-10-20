//
//  WalletConnectSocket.swift
//  ColdVault
//
//  The connection to the WalletConnect relay (a WebSocket), built on URLSession instead of a third
//  party library. It follows the same proxy as the rest of the app, so with Tor on the relay is
//  reached through Tor too.
//

import Foundation
import WalletConnectRelay

final class URLSessionWebSocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate {
    var request: URLRequest
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?
    private(set) var isConnected = false

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let delegateQueue = OperationQueue()

    init(url: URL) {
        request = URLRequest(url: url)
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
    }

    func connect() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 60 : 30
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    func disconnect() {
        lock.lock()
        let current = task
        lock.unlock()
        current?.cancel(with: .goingAway, reason: nil)
        closed(nil)
    }

    func write(string: String, completion: (() -> Void)?) {
        lock.lock()
        let current = task
        lock.unlock()
        current?.send(.string(string)) { _ in completion?() }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.lock.lock()
            let isCurrent = task === self.task
            self.lock.unlock()
            guard isCurrent else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.onText?(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.onText?(text) }
                @unknown default: break
                }
                self.receive(on: task)
            case .failure(let error):
                self.closed(error)
            }
        }
    }

    /// The socket ended (closed, failed, or cancelled here): tell the SDK once.
    private func closed(_ error: Error?) {
        lock.lock()
        let wasOpen = task != nil
        task = nil
        let old = session
        session = nil
        isConnected = false
        lock.unlock()
        old?.invalidateAndCancel()
        if wasOpen { onDisconnect?(error) }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        isConnected = true
        lock.unlock()
        onConnect?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closed(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { closed(error) }
    }
}

struct URLSessionSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        URLSessionWebSocket(url: url)
    }
}
