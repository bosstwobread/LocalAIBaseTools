import XCTest
@testable import MacHelperCapabilities

final class StreamDecoderTests: XCTestCase {
    func testStreamingIsRequestedOnlyWhenConsumerIsPresent() throws {
        let request = try CapabilityAIRequest(id: "request", action: "translate", text: "hello")
        let plain = try object(CapabilityFrame.encodeRequest(request, streaming: false))
        let streaming = try object(CapabilityFrame.encodeRequest(request, streaming: true))
        XCTAssertNil(plain["stream"])
        XCTAssertEqual(streaming["stream"] as? Bool, true)
        XCTAssertEqual(streaming["text"] as? String, "hello")
        XCTAssertEqual(streaming["action"] as? String, "translate")
        XCTAssertEqual(streaming["id"] as? String, "request")
    }

    func testOrderedDeltasAreProgressUntilNormalTerminalReply() throws {
        var decoder = CapabilityStreamDecoder(expectedID: "request", permitsProgress: true)
        XCTAssertEqual(try decoder.decode(data(["id": "request", "event": "delta", "delta": "你", "model": "actual-model"])),
                       .progress(delta: "你", model: "actual-model"))
        XCTAssertFalse(decoder.completed)
        XCTAssertEqual(try decoder.decode(data(["id": "request", "event": "delta", "delta": "好"])),
                       .progress(delta: "好", model: nil))
        let final = try decoder.decode(data(["id": "request", "ok": true, "text": "你好", "model": "actual-model"]))
        guard case .complete(let response) = final else { return XCTFail("Expected terminal reply") }
        XCTAssertEqual(response.text, "你好")
        XCTAssertTrue(decoder.completed)
        XCTAssertThrowsError(try decoder.decode(data(["id": "request", "event": "delta", "delta": "late"])))
    }

    func testProgressRejectsWrongRequestMalformedEventsAndUnrequestedStreaming() throws {
        let cases: [[String: Any]] = [
            ["id": "other", "event": "delta", "delta": "private"],
            ["id": "request", "event": "unknown", "delta": "text"],
            ["id": "request", "event": "delta"],
            ["id": "request", "event": "delta", "delta": "text", "ok": false]
        ]
        for value in cases {
            var decoder = CapabilityStreamDecoder(expectedID: "request", permitsProgress: true)
            XCTAssertThrowsError(try decoder.decode(data(value)))
        }
        var plain = CapabilityStreamDecoder(expectedID: "request", permitsProgress: false)
        XCTAssertThrowsError(try plain.decode(data(["id": "request", "event": "delta", "delta": "text"])))
    }

    func testCumulativeDeltaBudgetIsBoundedAcrossValidSizedFrames() throws {
        var decoder = CapabilityStreamDecoder(expectedID: "request", permitsProgress: true)
        let payload = try data(["id": "request", "event": "delta", "delta": String(repeating: "a", count: 140_000)])
        XCTAssertLessThan(payload.count, CapabilityFrame.maximumBytes)
        _ = try decoder.decode(payload)
        XCTAssertThrowsError(try decoder.decode(payload))
    }

    func testTerminalFailureAfterProgressNeverReturnsPartialAsSuccess() throws {
        var decoder = CapabilityStreamDecoder(expectedID: "request", permitsProgress: true)
        _ = try decoder.decode(data(["id": "request", "event": "delta", "delta": "unfinished"]))
        XCTAssertThrowsError(try decoder.decode(data(["id": "request", "ok": false, "error": "Provider failed"]))) { error in
            XCTAssertEqual(error as? CapabilityError, .failed("Provider failed"))
        }
        XCTAssertTrue(decoder.completed)
        XCTAssertThrowsError(try decoder.decode(data(["id": "request", "event": "delta", "delta": "late"])))
    }

    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func object(_ frame: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.dropFirst(4))) as? [String: Any])
    }
}
