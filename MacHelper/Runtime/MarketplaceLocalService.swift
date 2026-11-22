import Foundation
import Network
import Security

/// A narrow, same-machine bridge for the official marketplace. This is not a
/// general AI server: a session can only search public extension descriptions.
@MainActor
public final class MarketplaceLocalService {
    nonisolated public static let port: UInt16 = 43827
    nonisolated public static let origin = "https://local-ai-extension.nelson007.com"
    nonisolated public static let version = "6.7.6"
    nonisolated public static let maximumResponseBytes = 256 * 1024
    public typealias Search = @MainActor (String, String) async throws -> DiscoverySearchResult
    public typealias Cancel = @MainActor () async -> Void
    public enum State: Equatable, Sendable { case stopped, starting, ready, failed(String) }
    public private(set) var state: State = .stopped {
        didSet { onStateChange?(state) }
    }
    public private(set) var boundPort: UInt16?
    public var onStateChange: (@MainActor (State) -> Void)?

    private let requestedPort: UInt16
    private let search: Search
    private let cancel: Cancel
    private let queue = DispatchQueue(label: "com.localaibasetools.marketplace-loopback")
    private var listener: NWListener?
    private var generation = UUID()
    private var connections: [UUID: Connection] = [:]
    private struct Session { let expires: Date; var lastUsed: UInt64 }
    private var sessions: [String: Session] = [:]
    private var sessionOrder: UInt64 = 0
    private var active: Operation?
    private var cancelling = false
    private let now: () -> Date

    public convenience init(port: UInt16 = MarketplaceLocalService.port) {
        let engine = DiscoverySearchEngine()
        self.init(port: port, search: { try await engine.search(query: $0, language: $1) },
                  cancel: { await engine.cancel() })
    }

    public init(port: UInt16 = MarketplaceLocalService.port, search: @escaping Search,
                cancel: @escaping Cancel, now: @escaping () -> Date = Date.init) {
        requestedPort = port; self.search = search; self.cancel = cancel; self.now = now
    }

    /// The listener is always IPv4 loopback, including tests that request port 0.
    /// Ready/failure is asynchronous; opening settings does not start any AI work.
    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort)!)
        let candidate = try NWListener(using: parameters)
        let current = UUID(); generation = current
        listener = candidate; state = .starting
        candidate.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == current, self.listener != nil else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        candidate.stateUpdateHandler = { [weak self, weak candidate] update in
            Task { @MainActor in
                guard let self, self.generation == current, self.listener === candidate else { return }
                switch update {
                case .ready:
                    self.boundPort = candidate?.port?.rawValue
                    self.state = .ready
                case .failed:
                    self.stop()
                    self.state = .failed("The website connection could not start. Quit other copies of MacHelper, then reopen MacHelper.")
                default: break
                }
            }
        }
        candidate.start(queue: queue)
    }

    public func stop() {
        generation = UUID()
        listener?.cancel(); listener = nil; boundPort = nil
        if let operation = active { cancelOperation(operation.connectionID) }
        for context in connections.values { context.timeout?.cancel(); context.network.cancel() }
        connections.removeAll(); sessions.removeAll(); state = .stopped
    }

    private final class Connection {
        let network: NWConnection
        var decoder = MarketplaceHTTPRequestDecoder()
        var request: MarketplaceHTTPRequest?
        var timeout: Task<Void, Never>?
        var sending = false
        init(_ network: NWConnection) { self.network = network }
    }
    private final class Operation {
        let connectionID: UUID
        let token: String
        let requestID: String
        var task: Task<Void, Never>?
        var cancelled = false
        init(connectionID: UUID, token: String, requestID: String) {
            self.connectionID = connectionID; self.token = token; self.requestID = requestID
        }
    }

    private func accept(_ network: NWConnection) {
        guard connections.count < 16 else { network.cancel(); return }
        let id = UUID(), context = Connection(network)
        connections[id] = context
        network.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.disconnected(id) } }
            if case .cancelled = state { Task { @MainActor in self?.disconnected(id) } }
        }
        network.start(queue: queue)
        setTimeout(id, seconds: 10)
        receive(id)
    }

    private func setTimeout(_ id: UUID, seconds: UInt64) {
        guard let context = connections[id] else { return }
        context.timeout?.cancel()
        context.timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self, self.connections[id] != nil else { return }
            self.cancelOperation(id)
            self.reply(id, status: 408, object: Self.error("request_timeout", "The local request timed out. Try again."))
        }
    }

    private func receive(_ id: UUID) {
        guard let context = connections[id], !context.sending else { return }
        context.network.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let context = self.connections[id], !context.sending else { return }
                // Once a full request has been received, a second receive watches
                // for fetch aborts and forbidden pipelining while inference runs.
                if context.request != nil {
                    if data?.isEmpty == false || complete || error != nil { self.disconnected(id) }
                    else { self.receive(id) }
                    return
                }
                do {
                    if let data, let request = try context.decoder.append(data) {
                        context.request = request
                        self.route(request, id: id)
                        if self.active?.connectionID == id { self.receive(id) }
                    } else if complete || error != nil { self.disconnected(id) }
                    else { self.receive(id) }
                } catch {
                    self.reply(id, status: 400, object: Self.error("invalid_query", "The local request is invalid."))
                }
            }
        }
    }

    private func route(_ request: MarketplaceHTTPRequest, id: UUID) {
        guard let port = boundPort, request.headers["host"] == "127.0.0.1:\(port)",
              request.headers["origin"] == Self.origin else {
            reply(id, status: 403, object: Self.error("forbidden", "Only the official marketplace may connect.")); return
        }
        let paths = ["/v1/status", "/v1/session", "/v1/search", "/v1/cancel"]
        guard paths.contains(request.path) else {
            reply(id, status: 404, object: Self.error("not_found", "This local API is unavailable.")); return
        }
        if request.method == "OPTIONS" {
            let method = request.headers["access-control-request-method"]
            let headers = Set((request.headers["access-control-request-headers"] ?? "").lowercased()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let expectedMethod = request.path == "/v1/status" ? "GET" : "POST"
            guard method == expectedMethod, headers.contains("x-machelper-client"),
                  headers.isSubset(of: ["x-machelper-client", "content-type", "authorization"]) else {
                reply(id, status: 403, object: Self.error("forbidden", "The local connection headers are invalid.")); return
            }
            reply(id, status: 204, object: nil, preflight: true); return
        }
        guard request.headers["x-machelper-client"] == "extension-market" else {
            reply(id, status: 403, object: Self.error("forbidden", "The local client is invalid.")); return
        }
        guard request.method == (request.path == "/v1/status" ? "GET" : "POST") else {
            reply(id, status: 405, object: Self.error("invalid_query", "The local request method is invalid.")); return
        }
        if request.path == "/v1/status" {
            reply(id, status: 200, object: ["ok": true, "version": Self.version, "protocolVersion": 1]); return
        }
        let contentType = request.headers["content-type"]?.lowercased().split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
        guard contentType == "application/json", let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            reply(id, status: 400, object: Self.error("invalid_query", "The local request must contain JSON data.")); return
        }
        if request.path == "/v1/session" {
            guard object.isEmpty else {
                reply(id, status: 400, object: Self.error("invalid_query", "The connection request must be empty.")); return
            }
            sessions = sessions.filter { $0.value.expires > now() || $0.key == active?.token }
            if sessions.count >= 16 {
                // A browser reinstall/reload must not strand a new connection
                // behind abandoned tabs. Retain the active owner's cancellation
                // credential and retire the least recently used idle session.
                if let oldest = sessions.filter({ $0.key != active?.token }).min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                    sessions.removeValue(forKey: oldest.key)
                } else {
                    reply(id, status: 429, object: Self.error("busy", "The website connection is busy. Try again shortly.")); return
                }
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                reply(id, status: 500, object: Self.error("internal", "A local session could not be created.")); return
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            sessionOrder &+= 1
            sessions[token] = Session(expires: now().addingTimeInterval(1800), lastUsed: sessionOrder)
            reply(id, status: 200, object: ["ok": true, "token": token, "expiresIn": 1800]); return
        }
        guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer "),
              authorization.utf8.count == 71 else { unauthorized(id); return }
        let token = String(authorization.dropFirst(7))
        guard var session = sessions[token], session.expires > now() ||
                (request.path == "/v1/cancel" && active?.token == token) else {
            if active?.token != token { sessions.removeValue(forKey: token) }
            unauthorized(id); return
        }
        sessionOrder &+= 1; session.lastUsed = sessionOrder; sessions[token] = session
        guard let requestID = object["requestId"] as? String,
              requestID.range(of: #"\A[A-Za-z0-9_-]{1,80}\z"#, options: .regularExpression) != nil else {
            reply(id, status: 400, object: Self.error("invalid_query", "A valid search ID is required.")); return
        }
        if request.path == "/v1/cancel" {
            guard Set(object.keys) == ["requestId"] else {
                reply(id, status: 400, object: Self.error("invalid_query", "The cancellation request is invalid.")); return
            }
            if let operation = active, operation.token == token, operation.requestID == requestID {
                cancelOperation(operation.connectionID)
                reply(operation.connectionID, status: 409, object: Self.error("cancelled", "The search was cancelled."))
            }
            reply(id, status: 200, object: ["ok": true, "cancelled": true]); return
        }
        guard Set(object.keys) == ["requestId", "query", "language"], let query = object["query"] as? String,
              let language = object["language"] as? String,
              AppLocalization.supportedLanguages.contains(where: { $0.code == language }),
              (try? DiscoveryQuery.validate(query)) != nil else {
            reply(id, status: 400, object: Self.error("invalid_query", DiscoveryError.invalidQuery.localizedDescription)); return
        }
        guard active == nil, !cancelling else {
            reply(id, status: 429, object: Self.error("busy", "A website search is already running. Wait or cancel it first.")); return
        }
        let operation = Operation(connectionID: id, token: token, requestID: requestID)
        active = operation; setTimeout(id, seconds: 240)
        operation.task = Task { @MainActor [weak self, weak operation] in
            guard let self, let operation else { return }
            do {
                let answer = try await self.search(query, language)
                guard self.active === operation, !operation.cancelled, !Task.isCancelled else { return }
                self.active = nil
                let data = try JSONEncoder().encode(answer)
                let result = try JSONSerialization.jsonObject(with: data)
                self.reply(id, status: 200, object: ["ok": true, "version": Self.version, "search": result])
            } catch {
                guard self.active === operation, !operation.cancelled else { return }
                self.active = nil
                let cancelled = error is CancellationError || Task.isCancelled
                self.reply(id, status: cancelled ? 409 : 502,
                           object: Self.error(cancelled ? "cancelled" : "search_failed",
                                              cancelled ? "The search was cancelled." : "AI search failed. Check AI Connection in MacHelper and try again."))
            }
        }
    }

    private func unauthorized(_ id: UUID) {
        reply(id, status: 401, object: Self.error("unauthorized", "Connect to MacHelper again before searching."))
    }
    private static func error(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "code": code, "error": message]
    }
    private func cancelOperation(_ id: UUID) {
        guard let operation = active, operation.connectionID == id, !operation.cancelled else { return }
        operation.cancelled = true; operation.task?.cancel(); cancelling = true
        Task { @MainActor in
            await cancel()
            // Disconnecting a provider is not the same as completing its task.
            // Wait for engine ticket/client cleanup before admitting a retry.
            await operation.task?.value
            if active === operation { active = nil }
            cancelling = false
        }
    }
    private func disconnected(_ id: UUID) {
        guard let context = connections.removeValue(forKey: id) else { return }
        context.timeout?.cancel(); context.network.cancel()
        cancelOperation(id)
    }
    private func reply(_ id: UUID, status: Int, object: [String: Any]?, preflight: Bool = false) {
        guard let context = connections[id], !context.sending else { return }
        var status = status
        var bytes = object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
        if bytes.count > Self.maximumResponseBytes {
            status = 502
            bytes = try! JSONSerialization.data(withJSONObject: Self.error("search_failed", "The search result exceeds its size limit."))
        }
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict",
                      429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway"][status] ?? "Error"
        var headers = ["HTTP/1.1 \(status) \(reason)", "Content-Length: \(bytes.count)", "Content-Type: application/json; charset=utf-8",
                       "Cache-Control: no-store", "X-Content-Type-Options: nosniff", "Connection: close"]
        if context.request?.headers["origin"] == Self.origin {
            headers += ["Access-Control-Allow-Origin: \(Self.origin)", "Vary: Origin"]
            if preflight {
                headers += ["Access-Control-Allow-Methods: GET, POST, OPTIONS",
                            "Access-Control-Allow-Headers: authorization, content-type, x-machelper-client", "Access-Control-Max-Age: 600"]
            }
        }
        let response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + bytes
        context.sending = true; context.timeout?.cancel()
        context.network.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.disconnected(id) }
        })
    }
}

struct MarketplaceHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// Deliberately accepts one bounded HTTP/1.1 request, not a proxy or web server.
/// No transfer encoding, upgrade, ambiguous headers, trailers, or pipelining.
struct MarketplaceHTTPRequestDecoder {
    static let maximumHeaderBytes = 8 * 1024
    static let maximumBodyBytes = 16 * 1024
    private var buffer = Data()
    private var parsed: (String, String, [String: String], Int, Int)?
    private var finished = false

    mutating func append(_ bytes: Data) throws -> MarketplaceHTTPRequest? {
        guard !finished, buffer.count + bytes.count <= Self.maximumHeaderBytes + Self.maximumBodyBytes else { throw DiscoveryError.invalidQuery }
        buffer.append(bytes)
        if parsed == nil {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= Self.maximumHeaderBytes else { throw DiscoveryError.invalidQuery }
                return nil
            }
            let offset = separator.upperBound
            guard offset <= Self.maximumHeaderBytes,
                  buffer[..<separator.lowerBound].allSatisfy({ (32...126).contains($0) || $0 == 9 || $0 == 13 || $0 == 10 }),
                  let header = String(data: buffer[..<separator.lowerBound], encoding: .ascii) else { throw DiscoveryError.invalidQuery }
            let lines = header.components(separatedBy: "\r\n")
            guard let first = lines.first, lines.count <= 65 else { throw DiscoveryError.invalidQuery }
            let parts = first.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, ["GET", "POST", "OPTIONS"].contains(String(parts[0])), parts[2] == "HTTP/1.1",
                  parts[1].hasPrefix("/"), !parts[1].contains("?"), !parts[1].contains("#") else { throw DiscoveryError.invalidQuery }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw DiscoveryError.invalidQuery }
                let name = String(line[..<colon]).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard name.range(of: #"\A[a-z0-9!#$%&'*+.^_`|~-]+\z"#, options: .regularExpression) != nil,
                      headers[name] == nil, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DiscoveryError.invalidQuery }
                headers[name] = value
            }
            guard headers["host"] != nil, headers["transfer-encoding"] == nil, headers["expect"] == nil,
                  headers["upgrade"] == nil else { throw DiscoveryError.invalidQuery }
            let length: Int
            if let raw = headers["content-length"] {
                guard raw.range(of: #"\A[0-9]{1,6}\z"#, options: .regularExpression) != nil, let count = Int(raw),
                      count <= Self.maximumBodyBytes else { throw DiscoveryError.invalidQuery }
                length = count
            } else {
                guard parts[0] != "POST" else { throw DiscoveryError.invalidQuery }
                length = 0
            }
            guard parts[0] == "POST" || length == 0 else { throw DiscoveryError.invalidQuery }
            parsed = (String(parts[0]), String(parts[1]), headers, length, offset)
        }
        guard let (method, path, headers, length, offset) = parsed else { return nil }
        guard buffer.count <= offset + length else { throw DiscoveryError.invalidQuery }
        guard buffer.count == offset + length else { return nil }
        finished = true
        return .init(method: method, path: path, headers: headers, body: buffer.subdata(in: offset..<buffer.count))
    }
}
