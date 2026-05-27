import Foundation
import Network
import Combine

/// The bridge that listens for Claude Code hook events on localhost. The MVP
/// only ingests events and republishes them; later PRs add the approval queue,
/// hook installation, and the response path that lets users actually allow /
/// deny tool calls from the notch.
///
/// Server is bound to 127.0.0.1 only — never reachable off the machine.
@MainActor
final class ClaudeCodeBridge: ObservableObject {
    static let shared = ClaudeCodeBridge()

    /// The local port that hook scripts POST events to. Chosen to be different
    /// from Masko's `49152` so both apps can run side by side during testing.
    static let port: UInt16 = 21064

    @Published private(set) var isListening: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastEvent: ClaudeCodeIncomingEvent?
    @Published private(set) var totalEventsSeen: Int = 0

    private var listener: NWListener?
    private var connections: [NWConnection] = []

    private init() {}

    func start() {
        guard listener == nil else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: Self.port)!
            )
            let listener = try NWListener(using: params)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.lastError = nil
                    case .failed(let error):
                        self.isListening = false
                        self.lastError = "Listener failed: \(error.localizedDescription)"
                        self.listener = nil
                    case .cancelled:
                        self.isListening = false
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    self?.accept(conn)
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            lastError = "Failed to start listener on :\(Self.port): \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isListening = false
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                if case .cancelled = state {
                    self.connections.removeAll(where: { $0 === connection })
                }
            }
        }
        receive(on: connection, buffer: Data())
        connection.start(queue: .global(qos: .userInitiated))
    }

    /// Naive HTTP/1.1 reader. The hook script we ship will be a tiny POSIX
    /// shell script, so the request shape is fixed: small JSON body, no
    /// keep-alive, no chunked encoding. Adequate for MVP — replace with a
    /// proper parser if we ever accept third-party clients.
    private nonisolated func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("ClaudeCodeBridge: receive error \(error.localizedDescription)")
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let request = HTTPRequest.tryParse(accumulated) {
                Task { @MainActor in
                    let response = await self.handle(request: request)
                    let bytes = response.serialize()
                    connection.send(content: bytes, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    /// Routes the request based on path. For now `POST /event` is the only
    /// endpoint Brow honours; everything else gets a 404.
    private func handle(request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/event"):
            guard let parsed = ClaudeCodeIncomingEvent.decode(from: request.body) else {
                return .badRequest("Could not parse event JSON")
            }
            ingest(parsed)
            // MVP auto-allow + correctly shaped Claude Code hookSpecificOutput.
            // Future PRs block here until the user picks Allow / Always / Deny.
            return .ok(jsonBody: defaultDecision(for: parsed))
        case ("GET", "/healthz"):
            return .ok(jsonBody: #"{"ok":true}"#)
        default:
            return .notFound
        }
    }

    private func ingest(_ event: ClaudeCodeIncomingEvent) {
        lastEvent = event
        totalEventsSeen += 1
    }

    /// MVP decision shape — auto-allow every PreToolUse with a properly
    /// formed `hookSpecificOutput`, and acknowledge other hooks silently.
    /// Subsequent PRs replace this with the queue-driven response path.
    private func defaultDecision(for event: ClaudeCodeIncomingEvent) -> String {
        switch event.event {
        case .preToolUse:
            return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#
        case .notification, .unknown:
            return "{}"
        }
    }
}

// MARK: - HTTP support (minimal, internal)

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func tryParse(_ data: Data) -> HTTPRequest? {
        // Locate end of headers (CRLF CRLF)
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEndRange = data.range(of: separator) else { return nil }

        let headerData = data.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEndRange.upperBound
        let body: Data
        if let contentLength = headers["content-length"].flatMap(Int.init), contentLength > 0 {
            guard data.count >= bodyStart + contentLength else { return nil }
            body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            body = Data()
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    let bodyData: Data
    let contentType: String

    static func ok(jsonBody: String) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK",
                     bodyData: Data(jsonBody.utf8),
                     contentType: "application/json")
    }
    static func badRequest(_ message: String) -> HTTPResponse {
        HTTPResponse(status: 400, reason: "Bad Request",
                     bodyData: Data(message.utf8),
                     contentType: "text/plain")
    }
    static var notFound: HTTPResponse {
        HTTPResponse(status: 404, reason: "Not Found",
                     bodyData: Data("not found".utf8),
                     contentType: "text/plain")
    }

    func serialize() -> Data {
        var output = "HTTP/1.1 \(status) \(reason)\r\n"
        output += "Content-Type: \(contentType)\r\n"
        output += "Content-Length: \(bodyData.count)\r\n"
        output += "Connection: close\r\n"
        output += "\r\n"
        var bytes = Data(output.utf8)
        bytes.append(bodyData)
        return bytes
    }
}
