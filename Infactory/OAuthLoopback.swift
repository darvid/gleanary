import Foundation
import Network

actor OAuthLoopback {
    private var listener: NWListener?
    private var startup: CheckedContinuation<URL, any Error>?
    private var callback: CheckedContinuation<URL, any Error>?
    private var received: URL?
    private var redirect: URL?
    private var expectedState: String?
    private var stopped = false
    private var acceptedConnections = 0

    func start() async throws -> URL {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard listener == nil else { throw ChatGPTError.busy }
        let parameters = NWParameters.tcp
        // Bind IPv4 loopback only; do not expose an OAuth callback on the LAN.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                listener.start(queue: DispatchQueue(label: "app.getinfactory.oauth.loopback"))
            }
        } onCancel: { Task { await self.stop() } }
    }

    func expect(state: String) {
        expectedState = state
    }

    func wait() async throws -> URL {
        if let received {
            return received
        }
        guard !stopped else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback = $0 }
        } onCancel: { Task { await self.stop() } }
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        startup?.resume(throwing: CancellationError())
        startup = nil
        callback?.resume(throwing: CancellationError())
        callback = nil
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")
            else {
                startup?.resume(throwing: ChatGPTError.invalidCallback)
                startup = nil
                return
            }
            redirect = url
            startup?.resume(returning: url)
            startup = nil
        case .failed:
            startup?.resume(throwing: ChatGPTError.network)
            startup = nil
            callback?.resume(throwing: ChatGPTError.network)
            callback = nil
            listener?.cancel()
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, acceptedConnections < 32 else { connection.cancel(); return }
        acceptedConnections += 1
        connection.start(queue: DispatchQueue(label: "app.getinfactory.oauth.callback"))
        read(connection, buffer: Data())
        Task {
            try? await Task.sleep(for: .seconds(10))
            connection.cancel()
        }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection
            .receive(
                minimumIncompleteLength: 1,
                maximumLength: 8192
            ) { [weak self] data, _, complete, error in
                Task { await self?.receive(
                    connection,
                    buffer: buffer + (data ?? Data()),
                    complete: complete,
                    failed: error != nil
                ) }
            }
    }

    private func receive(_ connection: NWConnection, buffer: Data, complete: Bool, failed: Bool) {
        guard !stopped, !failed, buffer.count <= 16384 else { connection.cancel(); return }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if complete {
                connection.cancel()
            } else {
                read(connection, buffer: buffer)
            }
            return
        }
        let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let request = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard request.count == 3, request[0] == "GET", request[1].hasPrefix("/auth/callback?"),
              let redirect, let port = redirect.port,
              let url = URL(string: "http://127.0.0.1:\(port)" + request[1]),
              url.path == "/auth/callback", url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              let expectedState, items.first(where: { $0.name == "state" })?.value == expectedState,
              received == nil
        else {
            reply(
                connection,
                status: "400 Bad Request",
                body: "This callback does not match an active Infactory sign-in. Return to Infactory and try again."
            )
            return
        }
        reply(
            connection,
            status: "200 OK",
            body: "Authorization received. Return to Infactory; account verification is continuing. You can close this tab."
        )
        received = url
        callback?.resume(returning: url)
        callback = nil
        listener?.cancel()
        listener = nil
    }

    private func reply(_ connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(header.utf8) + bytes,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
