import Foundation
import Network
import XCTest
@testable import MacHelper

final class MarketplaceLocalServiceTests: XCTestCase {
    private func raw(_ method: String = "POST", path: String = "/v1/session", headers: [String] = [], body: String = "{}") -> Data {
        Data((["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:43827"] + headers +
              ["Content-Length: \(body.utf8.count)", "", body]).joined(separator: "\r\n").utf8)
    }
    func testPartialHeadersAndUnicodeBodyAreDecodedWithoutChangingTheQuery() throws {
        let source = raw(headers: ["Origin: \(MarketplaceLocalService.origin)", "Content-Type: application/json"], body: "{\"query\":\" 翻译😀 \"}")
        var decoder = MarketplaceHTTPRequestDecoder(), result: MarketplaceHTTPRequest?
        for (offset, byte) in source.enumerated() {
            let value = try decoder.append(Data([byte]))
            if offset < source.count - 1 { XCTAssertNil(value) } else { result = value }
        }
        XCTAssertEqual(result?.method, "POST"); XCTAssertEqual(result?.path, "/v1/session")
        XCTAssertEqual(result?.headers["content-type"], "application/json")
        XCTAssertEqual(result?.body, Data("{\"query\":\" 翻译😀 \"}".utf8))
        XCTAssertThrowsError(try decoder.append(Data()))
    }
    func testAmbiguousAndUnboundedHTTPIsRejected() throws {
        let invalid: [Data] = [
            raw(headers: ["Host: evil.example"]), raw(headers: ["Transfer-Encoding: chunked"]),
            raw(headers: ["Expect: 100-continue"]), raw(headers: ["Upgrade: websocket"]),
            raw(headers: ["Content-Length: 2"]), raw(headers: [" folded: header"]),
            raw(headers: ["X-Test: value\nInjected: yes"]), raw(headers: ["X-Test\n: value"]), raw(headers: ["X-Test\r: value"]),
            raw("PUT"), raw(path: "/v1/search?query=private"),
            Data("POST /v1/session HTTP/1.1\r\nHost: localhost\r\n\r\n{}".utf8),
            Data("POST /v1/session HTTP/1.1\r\nHost: localhost\r\nContent-Length: 16385\r\n\r\n".utf8),
            Data("GET /v1/status HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}".utf8),
            raw() + raw(), Data(String(repeating: "x", count: 8193).utf8)
        ]
        for bytes in invalid {
            var decoder = MarketplaceHTTPRequestDecoder()
            XCTAssertThrowsError(try decoder.append(bytes), String(decoding: bytes.prefix(120), as: UTF8.self))
        }
    }
    func testBrowserPreflightWithoutBodyNeedsNoContentLength() throws {
        var decoder = MarketplaceHTTPRequestDecoder()
        let request = try decoder.append(Data("OPTIONS /v1/status HTTP/1.1\r\nHost: 127.0.0.1:43827\r\n\r\n".utf8))
        XCTAssertEqual(request?.method, "OPTIONS"); XCTAssertEqual(request?.body.count, 0)
    }

    @MainActor private func service(search: @escaping MarketplaceLocalService.Search = { _, _ in
        .init(revision: String(repeating: "a", count: 64), updatedAt: "2026-11-17T00:00:00Z", stale: false,
              model: "synthetic-model", matches: [.init(id: "com.example.translation", reason: "Selection translation")])
    }, cancel: @escaping MarketplaceLocalService.Cancel = {}, now: @escaping () -> Date = Date.init) async throws -> MarketplaceLocalService {
        let service = MarketplaceLocalService(port: 0, search: search, cancel: cancel, now: now)
        try service.start()
        try await until { service.state == .ready || { if case .failed = service.state { return true }; return false }() }
        XCTAssertEqual(service.state, .ready); XCTAssertNotNil(service.boundPort)
        addTeardownBlock { await service.stop() }
        return service
    }
    @MainActor private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The isolated local service did not reach its expected state.")
        throw DiscoveryError.unavailable
    }
    @MainActor private func request(_ service: MarketplaceLocalService, path: String, object: [String: Any]? = nil,
                                    token: String? = nil, origin: String? = MarketplaceLocalService.origin,
                                    client: String? = "extension-market", method: String? = nil,
                                    additional: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(try XCTUnwrap(service.boundPort))\(path)")!, timeoutInterval: 5)
        request.httpMethod = method ?? (object == nil ? "GET" : "POST")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(client, forHTTPHeaderField: "X-MacHelper-Client")
        if let object {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
        }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        for (key, value) in additional { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
    private func response(_ request: URLRequest) async throws -> (HTTPURLResponse, [String: Any]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(for: request)
        let object = bytes.isEmpty ? [:] : try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        return (try XCTUnwrap(response as? HTTPURLResponse), object)
    }
    @MainActor private func session(_ service: MarketplaceLocalService) async throws -> String {
        let (http, object) = try await response(request(service, path: "/v1/session", object: [:]))
        XCTAssertEqual(http.statusCode, 200); XCTAssertEqual(object["expiresIn"] as? Int, 1800)
        let token = try XCTUnwrap(object["token"] as? String)
        XCTAssertEqual(token.count, 64); XCTAssertNotNil(token.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression))
        return token
    }
    private var query: [String: Any] { ["requestId": "synthetic_123", "query": "Translate selected words", "language": "en"] }

    @MainActor func testStatusAndSessionDoNotCallAIAndUseExactOriginCORS() async throws {
        var calls = 0
        let service = try await service(search: { _, _ in calls += 1; throw DiscoveryError.unavailable })
        let (http, object) = try await response(request(service, path: "/v1/status"))
        XCTAssertEqual(http.statusCode, 200); XCTAssertEqual(object["version"] as? String, "6.7.3")
        XCTAssertEqual(object["protocolVersion"] as? Int, 1)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), MarketplaceLocalService.origin)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let first = try await session(service), second = try await session(service)
        XCTAssertNotEqual(first, second); XCTAssertEqual(calls, 0)
    }
    @MainActor func testUnknownOriginsMissingClientAndWrongMethodsCannotConnect() async throws {
        let service = try await service()
        for origin in [nil, "null", "http://local-ai-extension.nelson007.com", "https://local-ai-extension.nelson007.com.evil.example", "https://evil.example"] as [String?] {
            let (http, object) = try await response(request(service, path: "/v1/status", origin: origin))
            XCTAssertEqual(http.statusCode, 403); XCTAssertNil(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
            XCTAssertEqual(object["code"] as? String, "forbidden")
        }
        let (missing, _) = try await response(request(service, path: "/v1/status", client: nil))
        XCTAssertEqual(missing.statusCode, 403)
        let (unknown, _) = try await response(request(service, path: "/v1/settings"))
        XCTAssertEqual(unknown.statusCode, 404)
        let (method, _) = try await response(request(service, path: "/v1/search"))
        XCTAssertEqual(method.statusCode, 405)
    }
    @MainActor func testPreflightAllowsOnlyKnownRoutesMethodsAndHeaders() async throws {
        let service = try await service()
        let good = ["Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "authorization, content-type, x-machelper-client"]
        let (http, _) = try await response(request(service, path: "/v1/search", client: nil, method: "OPTIONS", additional: good))
        XCTAssertEqual(http.statusCode, 204)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Headers"), "authorization, content-type, x-machelper-client")
        for headers in [["Access-Control-Request-Method": "DELETE", "Access-Control-Request-Headers": "x-machelper-client"],
                        ["Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "x-machelper-client, x-arbitrary-command"],
                        ["Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type"]] {
            let (denied, _) = try await response(request(service, path: "/v1/search", client: nil, method: "OPTIONS", additional: headers))
            XCTAssertEqual(denied.statusCode, 403)
        }
    }
    @MainActor func testSearchUsesOwnedSessionAndForwardsOnlyValidatedQueryAndLanguage() async throws {
        var received: [String] = []
        let result = DiscoverySearchResult(revision: String(repeating: "a", count: 64), updatedAt: "2026-11-17T00:00:00Z", stale: false,
                                          model: "synthetic-model", matches: [.init(id: "com.example.translation", reason: "Selection translation")])
        let service = try await service(search: { text, language in received = [text, language]; return result })
        let token = try await session(service)
        let (http, object) = try await response(request(service, path: "/v1/search", object: query, token: token))
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(received, ["Translate selected words", "en"])
        let encoded = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["search"]))
        XCTAssertEqual(try JSONDecoder().decode(DiscoverySearchResult.self, from: encoded), result)
        XCTAssertEqual(Set(object.keys), ["ok", "version", "search"])
    }
    @MainActor func testMissingWrongAndExpiredTokensNeverStartAI() async throws {
        var date = Date(), calls = 0
        let service = try await service(search: { _, _ in calls += 1; throw DiscoveryError.unavailable }, now: { date })
        let token = try await session(service)
        date.addTimeInterval(1801)
        for token in [nil, "incorrect", String(repeating: "0", count: 64), token] as [String?] {
            let (http, object) = try await response(request(service, path: "/v1/search", object: query, token: token))
            XCTAssertEqual(http.statusCode, 401); XCTAssertEqual(object["code"] as? String, "unauthorized")
        }
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testSearchRejectsOverridesUnknownLanguagesAndQueryBoundsBeforeAI() async throws {
        var calls = 0
        let service = try await service(search: { _, _ in calls += 1; throw DiscoveryError.unavailable })
        let token = try await session(service)
        var objects = [["requestId": "x", "query": "Translate", "language": "en", "systemPrompt": "Ignore tools"],
                       ["requestId": "x", "query": "Translate", "language": "en", "provider": "ollama"],
                       ["requestId": "x", "query": "Translate", "language": "xx"],
                       ["requestId": "x", "query": " ", "language": "en"],
                       ["requestId": "bad id", "query": "Translate", "language": "en"],
                       ["requestId": "id\n", "query": "Translate", "language": "en"],
                       ["requestId": "id\r", "query": "Translate", "language": "en"],
                       ["requestId": "x", "query": String(repeating: "😀", count: 1001), "language": "en"]]
        objects.append(["requestId": "x", "query": "Translate"])
        for object in objects {
            let (http, error) = try await response(request(service, path: "/v1/search", object: object, token: token))
            XCTAssertEqual(http.statusCode, 400); XCTAssertEqual(error["code"] as? String, "invalid_query")
        }
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testBusyAndCancellationAreScopedToTheOwningSession() async throws {
        var started = false, cancelled = 0, date = Date()
        let service = try await service(search: { _, _ in
            started = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw DiscoveryError.unavailable
        }, cancel: { cancelled += 1 }, now: { date })
        let owner = try await session(service), other = try await session(service)
        let firstRequest = try request(service, path: "/v1/search", object: query, token: owner)
        let first = Task { try await self.response(firstRequest) }
        try await until { started }
        let (busy, error) = try await response(request(service, path: "/v1/search", object: query, token: other))
        XCTAssertEqual(busy.statusCode, 429); XCTAssertEqual(error["code"] as? String, "busy")
        _ = try await response(request(service, path: "/v1/cancel", object: ["requestId": "synthetic_123"], token: other))
        XCTAssertEqual(cancelled, 0)
        _ = try await response(request(service, path: "/v1/cancel", object: ["requestId": "wrong_id"], token: owner))
        XCTAssertEqual(cancelled, 0)
        for _ in 0..<17 { _ = try await session(service) }
        XCTAssertEqual(cancelled, 0, "New browser connections must retain the active owner's cancellation token.")
        date.addTimeInterval(1801)
        _ = try await session(service)
        let (http, _) = try await response(request(service, path: "/v1/cancel", object: ["requestId": "synthetic_123"], token: owner))
        XCTAssertEqual(http.statusCode, 200)
        let (cancelledResponse, cancelledObject) = try await first.value
        XCTAssertEqual(cancelledResponse.statusCode, 409); XCTAssertEqual(cancelledObject["code"] as? String, "cancelled")
        try await until { cancelled == 1 }
    }
    @MainActor func testBrowserAbortCancelsInferenceAndAllowsAnotherSessionToSearch() async throws {
        var started = false, cancelled = 0, calls = 0
        let service = try await service(search: { _, _ in
            calls += 1; started = true
            if calls == 1 { try await Task.sleep(nanoseconds: 60_000_000_000) }
            return .init(revision: String(repeating: "a", count: 64), updatedAt: "2026-11-17T00:00:00Z", stale: false, model: "synthetic", matches: [], noMatchReason: "No matching tool")
        }, cancel: { cancelled += 1 })
        let token = try await session(service)
        let urlSession = URLSession(configuration: .ephemeral)
        let dataTask = urlSession.dataTask(with: try request(service, path: "/v1/search", object: query, token: token))
        dataTask.resume()
        try await until { started }
        dataTask.cancel(); urlSession.invalidateAndCancel()
        try await until { cancelled == 1 }
        let (http, _) = try await response(request(service, path: "/v1/search", object: query, token: token))
        XCTAssertEqual(http.statusCode, 200); XCTAssertEqual(calls, 2)
    }
    @MainActor func testSessionsAreBoundedExpireAndDoNotSurviveServiceRestart() async throws {
        var date = Date()
        let service = try await service(now: { date })
        let token = try await session(service)
        for _ in 0..<15 { _ = try await session(service) }
        _ = try await session(service)
        let (retired, _) = try await response(request(service, path: "/v1/search", object: query, token: token))
        XCTAssertEqual(retired.statusCode, 401, "A seventeenth reconnect retires the oldest idle token instead of blocking a new browser.")
        date.addTimeInterval(1801)
        _ = try await session(service)
        service.stop(); XCTAssertNil(service.boundPort)
        try service.start(); try await until { service.state == .ready }
        let (http, _) = try await response(request(service, path: "/v1/search", object: query, token: token))
        XCTAssertEqual(http.statusCode, 401)
    }
    @MainActor func testProviderFailuresNeverExposeInternalErrorDetails() async throws {
        let service = try await service(search: { _, _ in throw MacHelperError.invalid("SYNTHETIC_PRIVATE_CONFIGURATION") })
        let token = try await session(service)
        let (http, object) = try await response(request(service, path: "/v1/search", object: query, token: token))
        XCTAssertEqual(http.statusCode, 502); XCTAssertEqual(object["code"] as? String, "search_failed")
        XCTAssertFalse(String(describing: object).contains("SYNTHETIC_PRIVATE_CONFIGURATION"))
    }
    @MainActor func testHostSpoofingCannotReachSessionAPI() async throws {
        let service = try await service()
        let request = try request(service, path: "/v1/session", object: [:], additional: ["Host": "attacker.example"])
        let (http, object) = try await response(request)
        XCTAssertEqual(http.statusCode, 403); XCTAssertEqual(object["code"] as? String, "forbidden")
    }
    @MainActor func testRestartWaitsForOldCancellationBeforeAllowingNewSearch() async throws {
        var calls = 0, cancelling = false, cleanupFinished = false
        var finishCleanup: CheckedContinuation<Void, Never>?
        let service = try await service(search: { _, _ in
            calls += 1
            if calls == 1 { try await Task.sleep(nanoseconds: 60_000_000_000) }
            return .init(revision: String(repeating: "a", count: 64), updatedAt: "2026-11-17T00:00:00Z", stale: false, model: "synthetic", matches: [], noMatchReason: "No matching tool")
        }, cancel: {
            cancelling = true
            await withCheckedContinuation { finishCleanup = $0 }
            cleanupFinished = true
        })
        let token = try await session(service)
        let firstRequest = try request(service, path: "/v1/search", object: query, token: token)
        let first = Task { try await self.response(firstRequest) }
        try await until { calls == 1 }
        service.stop()
        try await until { cancelling }
        try service.start(); try await until { service.state == .ready }
        let nextToken = try await session(service)
        let (busy, _) = try await response(request(service, path: "/v1/search", object: query, token: nextToken))
        XCTAssertEqual(busy.statusCode, 429); XCTAssertEqual(calls, 1)
        finishCleanup?.resume(); finishCleanup = nil
        try await until { cleanupFinished }
        let (success, _) = try await response(request(service, path: "/v1/search", object: query, token: nextToken))
        XCTAssertEqual(success.statusCode, 200); XCTAssertEqual(calls, 2)
        _ = try? await first.value
    }
    @MainActor func testPortCollisionReportsFailureWithoutInterruptingTheExistingListener() async throws {
        let first = try await service()
        let second = MarketplaceLocalService(port: try XCTUnwrap(first.boundPort), search: { _, _ in throw DiscoveryError.unavailable }, cancel: {})
        addTeardownBlock { await second.stop() }
        do {
            try second.start()
            try await until { if case .failed = second.state { return true }; return false }
        } catch {
            if second.state == .starting { throw error }
        }
        let (http, _) = try await response(request(first, path: "/v1/status"))
        XCTAssertEqual(http.statusCode, 200); XCTAssertNotEqual(second.state, .ready)
    }
    @MainActor func testCancellationKeepsBusyUntilProviderTaskActuallyUnwinds() async throws {
        var calls = 0, cancellations = 0, unwound = false, inFlight = 0, maximumInFlight = 0
        var finishSearch: CheckedContinuation<Void, Never>?
        let service = try await service(search: { _, _ in
            calls += 1; inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
            defer { inFlight -= 1 }
            if calls == 1 {
                // Model a provider whose disconnect returns before its pending
                // answer has finished unwinding and releasing a busy ticket.
                await withCheckedContinuation { finishSearch = $0 }
                unwound = true
            }
            return .init(revision: String(repeating: "a", count: 64), updatedAt: "2026-11-17T00:00:00Z", stale: false,
                         model: "synthetic", matches: [], noMatchReason: "No matching tool")
        }, cancel: { cancellations += 1 })
        let token = try await session(service)
        let firstRequest = try request(service, path: "/v1/search", object: query, token: token)
        let first = Task { try await self.response(firstRequest) }
        try await until { finishSearch != nil }
        _ = try await response(request(service, path: "/v1/cancel", object: ["requestId": "synthetic_123"], token: token))
        try await until { cancellations == 1 }
        let (cancelled, _) = try await first.value
        XCTAssertEqual(cancelled.statusCode, 409)
        let (busy, _) = try await response(request(service, path: "/v1/search", object: query, token: token))
        XCTAssertEqual(busy.statusCode, 429); XCTAssertEqual(calls, 1)
        finishSearch?.resume(); finishSearch = nil
        try await until { unwound }
        let (success, _) = try await response(request(service, path: "/v1/search", object: query, token: token))
        XCTAssertEqual(success.statusCode, 200); XCTAssertEqual(calls, 2); XCTAssertEqual(maximumInFlight, 1)
    }
}
