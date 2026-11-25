import Darwin
import Foundation
import Network

/// Per-user IPC for approved browser companions. Payloads belong to the source
/// command, while the service owns authentication scope, framing and cancellation.
@MainActor
public final class CompanionService {
    public struct Route: Hashable, Sendable {
        public let extensionID: String
        public let companionID: String

        public init(extensionID: String, companionID: String) {
            self.extensionID = extensionID
            self.companionID = companionID
        }
    }

    public enum Failure: String, Error {
        case invalid, unavailable, busy, failed
    }

    public typealias Authorize = @MainActor (Route, String, String?) -> Bool
    public typealias Invoke = @MainActor (Route, String, String, String) async throws -> String

    public nonisolated static let maximumFrameBytes = 128 * 1024
    public nonisolated static let maximumPayloadBytes = 32 * 1024
    private static let maximumHandshakes = 8
    private static let maximumStatusWatchers = 16
    private static let maximumInvocationSockets = 8
    private static let maximumActiveInvocations = 4
    private let directory: URL?
    private let authorize: Authorize
    private let invoke: Invoke
    private let queue = DispatchQueue(label: "com.localaibasetools.companion")
    private var routes: [Route: String?] = [:]
    private var listener: NWListener?
    private var endpoint: Endpoint?
    private var connections: [UUID: Connection] = [:]
    private var activeInvocations: [String: UUID] = [:]

    private enum Request {
        case watch(Route)
        case invoke(Route, command: String, payload: String)

        init(_ data: Data) throws {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String, let extensionID = object["extension"] as? String,
                  extensionID.rangeOfCharacter(from: .controlCharacters) == nil,
                  (try? SourcePackageRules.validateIdentifier(extensionID)) != nil,
                  let companionID = object["companion"] as? String, companionID.utf8.count == 32,
                  companionID.utf8.allSatisfy({ (97...112).contains($0) }) else { throw Failure.invalid }
            let route = Route(extensionID: extensionID, companionID: companionID)
            let keys = Set(object.keys)
            switch type {
            case "watchStatus" where keys == ["type", "extension", "companion"]:
                self = .watch(route)
            case "invoke" where keys == ["type", "extension", "companion", "command", "payload"]:
                guard let command = object["command"] as? String, command.utf8.count <= 48,
                      command.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil,
                      let payload = object["payload"] as? String,
                      payload.utf8.count <= CompanionService.maximumPayloadBytes else { throw Failure.invalid }
                self = .invoke(route, command: command, payload: payload)
            default:
                throw Failure.invalid
            }
        }
    }

    private struct Reply: Encodable {
        let ok: Bool
        var payload: String? = nil
        var error: String? = nil
    }

    private struct Status: Encodable {
        let type = "status"
        let enabled: Bool
    }

    private final class Connection {
        enum Role: Equatable {
            case handshake
            case watcher(Route)
            case invocation(Route, generation: String, command: String)
        }

        let network: NWConnection
        var role: Role = .handshake
        var deadline: Task<Void, Never>?
        var invocation: Task<Void, Never>?
        var lastStatus: Bool?
        var writingStatus = false
        var pendingStatus: Bool?

        init(_ network: NWConnection) { self.network = network }
    }

    private struct Endpoint {
        let pointer: URL
        let socket: URL
        let lock: Int32
    }

    public init(directory: URL? = nil, authorize: @escaping Authorize, invoke: @escaping Invoke) {
        self.directory = directory
        self.authorize = authorize
        self.invoke = invoke
    }

    /// Keep a key with a nil generation to publish disabled status for an installed
    /// grant. Removing a key revokes it. Replacing a generation cancels its work.
    public func setRoutes(_ next: [Route: String?]) {
        routes = next
        guard !next.isEmpty else { stopListener(); return }
        for id in Array(connections.keys) {
            guard let connection = connections[id] else { continue }
            switch connection.role {
            case .handshake:
                break
            case .watcher(let route):
                guard routes.index(forKey: route) != nil else { close(id); continue }
                updateStatus(id, for: route)
            case .invocation(let route, let generation, let command):
                if !isAuthorized(route, generation: generation, command: command) { close(id) }
            }
        }
        if listener == nil {
            do { try startListener() }
            catch { stopListener() }
        }
    }

    private func isAuthorized(_ route: Route, generation: String, command: String?) -> Bool {
        (routes[route] ?? nil) == generation && authorize(route, generation, command)
    }

    private static func defaultDirectory() throws -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 1 else { throw Failure.unavailable }
        var path = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &path, length) == length,
              let directory = path.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }) else {
            throw Failure.unavailable
        }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("mh-companion", isDirectory: true)
    }

    private func startListener() throws {
        let directory = try directory ?? Self.defaultDirectory()
        var info = stat()
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST,
              lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (S_IFMT | 0o777) == S_IFDIR | 0o700 else { throw Failure.unavailable }
        let name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".sock"
        let socket = directory.appendingPathComponent(name)
        guard socket.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw Failure.unavailable }
        let descriptor = open(directory.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (S_IFMT | 0o777) == S_IFREG | 0o600,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw Failure.unavailable
        }
        let pointer = directory.appendingPathComponent("endpoint")
        endpoint = Endpoint(pointer: pointer, socket: socket, lock: descriptor)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socket.path)
        let candidate = try NWListener(using: parameters)
        listener = candidate
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            Task { @MainActor in
                guard let self, let candidate, self.listener === candidate else { return }
                switch state {
                case .ready:
                    do { try Data(name.utf8).write(to: pointer, options: .atomic) }
                    catch { self.stopListener() }
                case .failed, .cancelled:
                    self.stopListener()
                default:
                    break
                }
            }
        }
        candidate.newConnectionHandler = { [weak self, weak candidate] connection in
            Task { @MainActor in
                guard let self, let candidate, self.listener === candidate,
                      self.connections.values.filter({ $0.role == .handshake }).count < Self.maximumHandshakes else {
                    connection.cancel(); return
                }
                self.accept(connection)
            }
        }
        candidate.start(queue: queue)
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { close(id) }
        if let endpoint {
            unlink(endpoint.pointer.path)
            unlink(endpoint.socket.path)
            Darwin.close(endpoint.lock)
            self.endpoint = nil
        }
    }

    private func accept(_ network: NWConnection) {
        let id = UUID()
        connections[id] = Connection(network)
        setDeadline(id, seconds: 3)
        network.start(queue: queue)
        network.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, !ended, error == nil, let data, data.count == 4 else { self?.close(id); return }
                let length = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                guard (1...Self.maximumFrameBytes).contains(length) else { self.reply(id, error: .invalid); return }
                self.receiveBody(id, length: length)
            }
        }
    }

    private func receiveBody(_ id: UUID, length: Int) {
        guard let network = connections[id]?.network else { return }
        network.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, !ended, error == nil else { self?.close(id); return }
                guard let data, data.count == length, let request = try? Request(data) else {
                    self.reply(id, error: .invalid); return
                }
                switch request {
                case .watch(let route):
                    self.subscribe(id, to: route)
                case .invoke(let route, let command, let payload):
                    self.startInvocation(id, route: route, command: command, payload: payload)
                }
            }
        }
    }

    private func subscribe(_ id: UUID, to route: Route) {
        guard let connection = connections[id] else { return }
        guard routes.index(forKey: route) != nil else { reply(id, error: .unavailable); return }
        let watchers = connections.values.filter { connection in
            if case .watcher = connection.role { return true }
            return false
        }
        guard watchers.count < Self.maximumStatusWatchers else { reply(id, error: .busy); return }
        connection.role = .watcher(route)
        monitorDisconnect(connection, id: id)
        updateStatus(id, for: route)
    }

    private func updateStatus(_ id: UUID, for route: Route) {
        guard let connection = connections[id] else { return }
        let enabled = (routes[route] ?? nil).map { authorize(route, $0, nil) } ?? false
        guard connection.lastStatus != enabled else { return }
        connection.lastStatus = enabled
        writeStatus(enabled, id: id)
    }

    private func writeStatus(_ enabled: Bool, id: UUID) {
        guard let connection = connections[id] else { return }
        if connection.writingStatus {
            // Keep one pending change. A stalled reader reconnects for a fresh status.
            if connection.pendingStatus != nil { close(id) }
            else { connection.pendingStatus = enabled }
            return
        }
        guard let frame = Self.frame(Status(enabled: enabled)) else { close(id); return }
        connection.writingStatus = true
        setDeadline(id, seconds: 2)
        connection.network.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, let connection = self.connections[id] else { return }
                guard error == nil else { self.close(id); return }
                connection.deadline?.cancel()
                connection.deadline = nil
                connection.writingStatus = false
                if let pending = connection.pendingStatus {
                    connection.pendingStatus = nil
                    self.writeStatus(pending, id: id)
                }
            }
        })
    }

    private func monitorDisconnect(_ connection: Connection, id: UUID) {
        connection.network.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            // Either peer EOF or input after the initial frame ends the request.
            Task { @MainActor in self?.close(id) }
        }
    }

    private func startInvocation(_ id: UUID, route: Route, command: String, payload: String) {
        guard let connection = connections[id] else { return }
        guard let generation = routes[route] ?? nil, isAuthorized(route, generation: generation, command: command) else {
            reply(id, error: .unavailable); return
        }
        let invocations = connections.values.filter { connection in
            if case .invocation = connection.role { return true }
            return false
        }
        guard activeInvocations[route.extensionID] == nil, activeInvocations.count < Self.maximumActiveInvocations,
              invocations.count < Self.maximumInvocationSockets else { reply(id, error: .busy); return }
        connection.role = .invocation(route, generation: generation, command: command)
        activeInvocations[route.extensionID] = id
        setDeadline(id, seconds: 55)
        monitorDisconnect(connection, id: id)
        connection.invocation = Task { [weak self] in
            guard let self else { return }
            defer { self.activeInvocations.removeValue(forKey: route.extensionID) }
            do {
                try Task.checkCancellation()
                guard self.isAuthorized(route, generation: generation, command: command) else { self.close(id); return }
                let result = try await self.invoke(route, generation, command, payload)
                try Task.checkCancellation()
                guard self.isAuthorized(route, generation: generation, command: command) else { self.close(id); return }
                self.reply(id, payload: result)
            } catch {
                guard !Task.isCancelled else { return }
                guard self.isAuthorized(route, generation: generation, command: command) else { self.close(id); return }
                self.reply(id, error: (error as? Failure) ?? .failed)
            }
        }
    }

    private func setDeadline(_ id: UUID, seconds: UInt64) {
        connections[id]?.deadline?.cancel()
        connections[id]?.deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            self?.close(id)
        }
    }

    private func reply(_ id: UUID, payload: String? = nil, error: Failure? = nil) {
        guard let connection = connections[id] else { return }
        let response = Reply(ok: payload != nil, payload: payload, error: error?.rawValue)
        let frame = payload.map { $0.utf8.count > Self.maximumPayloadBytes } == true ? nil : Self.frame(response)
        guard let frame = frame ?? Self.frame(Reply(ok: false, error: Failure.failed.rawValue)) else { close(id); return }
        setDeadline(id, seconds: 2)
        connection.network.send(content: frame, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private static func frame(_ response: some Encodable) -> Data? {
        guard let data = try? JSONEncoder().encode(response), data.count <= maximumFrameBytes else { return nil }
        var length = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        return frame
    }

    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.deadline?.cancel()
        connection.invocation?.cancel()
        connection.network.cancel()
    }
}
