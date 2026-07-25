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
    /// Runtime context (terminal app, tty, cwd) from the most recently
    /// ingested envelope. Later tasks use this to enrich events; storing it
    /// here keeps this task's scope to parsing + routing only.
    private(set) var lastContext: AgentBridgeEnvelope.HookRuntimeContextDTO?

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
            guard let envelope = try? AgentBridgeEnvelope.decode(request.body) else {
                return .badRequest("Could not parse event JSON")
            }
            lastContext = envelope.context

            switch envelope.source {
            case "claude":
                break
            default:
                NSLog("ClaudeCodeBridge: unhandled source: \(envelope.source)")
                return .ok(jsonBody: "{}")
            }

            guard let payloadData = try? JSONSerialization.data(withJSONObject: envelope.payloadJSON),
                  let parsed = ClaudeCodeIncomingEvent.decode(from: payloadData) else {
                return .badRequest("Could not parse event JSON")
            }
            ingest(parsed)

            // ADDITIVE mirror (Task 1.7): fold the same event into the new
            // `AIAppModel`/`SessionState` reducer alongside the existing
            // `ClaudeCodeStore` calls below. Pure state mirror only — no
            // side effects, doesn't touch the store's approval queue or
            // continuation registry. `handle` already runs on the main
            // actor (see `receive`'s `Task { @MainActor in ... }`), so no
            // extra hop is needed to reach `@MainActor AIAppModel`.
            let mirroredEvents = ClaudeEventMapping.mapClaudeEvent(parsed, context: envelope.context)

            switch parsed.event {
            case .sessionStart(let payload):
                ClaudeCodeStore.shared.recordSessionStart(payload)
                AIAppModel.shared.ingest(mirroredEvents)
                return .ok(jsonBody: "{}")
            case .sessionEnd(let payload):
                ClaudeCodeStore.shared.recordSessionEnd(payload)
                AIAppModel.shared.ingest(mirroredEvents)
                return .ok(jsonBody: "{}")
            case .userPromptSubmit(let payload):
                ClaudeCodeStore.shared.recordUserPrompt(payload)
                AIAppModel.shared.ingest(mirroredEvents)
                return .ok(jsonBody: "{}")
            case .permissionRequest(let payload):
                // Task 1.8 fix: ingest the mirrored `.permissionRequested`
                // event BEFORE the blocking store call (not after, as Task
                // 1.7 left it), so `AIAppModel` shows `.waitingForApproval`
                // live while the user is actually deciding, not only once
                // the decision has already been made.
                AIAppModel.shared.ingest(mirroredEvents)
                // Suspends until the user decides in the notch, a saved
                // rule matches, or the store's 55s timeout fires.
                let body = await ClaudeCodeStore.shared.handlePermissionRequest(payload, rawJSON: parsed.rawJSON)
                // Reflect the resolution in the mirror so it leaves
                // `.waitingForApproval` once the store has decided.
                // `handlePermissionRequest` returns only the serialized
                // hook-response body (String), not an `ApprovalDecision`
                // value — recovering allow/deny from that string to call
                // `AIAppModel.shared.approve(sessionID:_:)` would mean
                // parsing the store's hook JSON back out (fragile: `.ask`
                // serializes to `"{}"` with no decision key at all), and
                // the store is out of scope to change here. `.actionableStateResolved`
                // is the reducer's decision-agnostic exit from
                // `.waitingForApproval`/`.waitingForAnswer` back to
                // `.running`, so use that instead — it needs only the
                // session id, which we already have.
                if let sessionID = payload.sessionID {
                    AIAppModel.shared.ingest([
                        .actionableStateResolved(ActionableStateResolved(
                            sessionID: sessionID,
                            summary: "Permission resolved.",
                            timestamp: Date()
                        ))
                    ])
                }
                return .ok(jsonBody: body)
            case .notification(let payload):
                ClaudeCodeStore.shared.recordNotification(payload)
                AIAppModel.shared.ingest(mirroredEvents)
                return .ok(jsonBody: "{}")
            case .stop(let payload):
                ClaudeCodeStore.shared.recordStop(payload)
                AIAppModel.shared.ingest(mirroredEvents)
                return .ok(jsonBody: "{}")
            case .unknown:
                return .ok(jsonBody: "{}")
            }
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
}

// MARK: - Agent bridge envelope

/// The enriched envelope `BrowAgentHook` POSTs: `{"source","payload","context"}`.
/// Back-compat: a raw Claude hook payload with no top-level `"source"` key
/// (the shape the legacy inline-curl hook still sends) is treated as
/// `source == "claude"` with the whole object as the payload.
struct AgentBridgeEnvelope {
    let source: String
    let payloadJSON: [String: Any]
    let context: HookRuntimeContextDTO?

    struct HookRuntimeContextDTO: Decodable { var terminalApp: String?; var tty: String?; var terminalSessionID: String?; var cwd: String? }

    static func decode(_ data: Data) throws -> AgentBridgeEnvelope {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AgentBridge", code: 1)
        }
        if let source = obj["source"] as? String, let payload = obj["payload"] as? [String: Any] {
            let ctx = (obj["context"] as? [String: Any]).flatMap {
                try? JSONDecoder().decode(HookRuntimeContextDTO.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            return AgentBridgeEnvelope(source: source, payloadJSON: payload, context: ctx)
        }
        return AgentBridgeEnvelope(source: "claude", payloadJSON: obj, context: nil)
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
