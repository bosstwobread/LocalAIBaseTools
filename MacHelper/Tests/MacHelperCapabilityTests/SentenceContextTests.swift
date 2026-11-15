import Foundation
import XCTest
@testable import MacHelperCapabilities

final class SentenceContextTests: XCTestCase {
    private func extract(_ document: String, selected: String) -> String? {
        let range = (document as NSString).range(of: selected)
        guard range.location != NSNotFound,
              let window = SelectionSentenceContext.window(selection: range, documentUTF16Length: document.utf16.count) else { return nil }
        return SelectionSentenceContext.sentence(selected: selected, selection: range,
            windowText: (document as NSString).substring(with: window), windowRange: window, documentUTF16Length: document.utf16.count)
    }

    func testLexicalWordsSupportUnicodeCombiningMarksContractionsAndHyphens() {
        for text in ["ready", "can't", "well-known", "co‑operate", "l’été", "e\u{301}lan", "B2B", "4th", "Schön", "παράδειγμα", "слово", "مرحبا", "  ready  ", "猫"] {
            XCTAssertTrue(SelectionSentenceContext.isSingleWord(text), text)
        }
        for text in ["", " ", "two words", "hello!", "--", "'", "’", "ʼ", "123", "12.5", "a--b", "-word", "word-", "a_b", "a/b", "🙂", "line\nbreak", String(repeating: "x", count: 129),
                     "今天天气非常好适合出去散步", "今日はとても良い天気です", "오늘날씨가정말좋아서산책합니다"] {
            XCTAssertFalse(SelectionSentenceContext.isSingleWord(text), text)
        }
    }

    func testEnclosingSentenceDoesNotIncludeAdjacentSentences() {
        XCTAssertEqual(extract("The project is ready for review. Send the summary tomorrow.", selected: "ready"), "The project is ready for review.")
        XCTAssertEqual(extract("First sentence. The project is ready for review! Final sentence.", selected: "ready"), "The project is ready for review!")
    }

    func testUTF16OffsetsPreserveEmojiAndCombiningMarks() {
        let emoji = "😀 We’re ready to go! Another sentence."
        let range = (emoji as NSString).range(of: "ready")
        XCTAssertNotEqual(range.location, emoji.distance(from: emoji.startIndex, to: emoji.range(of: "ready")!.lowerBound))
        XCTAssertEqual(extract(emoji, selected: "ready"), "😀 We’re ready to go!")
        XCTAssertEqual(extract("Son e\u{301}lan est remarquable. Ensuite, on verra.", selected: "e\u{301}lan"), "Son e\u{301}lan est remarquable.")
    }

    func testVerifiedDocumentEdgesPermitFirstAndLastSentence() {
        XCTAssertEqual(extract("Ready for review", selected: "Ready"), "Ready for review")
        XCTAssertEqual(extract("First sentence. We are ready", selected: "ready"), "We are ready")
    }

    func testLongDocumentCanYieldCompleteInteriorSentenceWithinBoundedWindow() {
        let document = String(repeating: "x", count: 1200) + ". The project is ready for review. The next sentence is " + String(repeating: "y", count: 1200) + "."
        let range = (document as NSString).range(of: "ready")
        let window = SelectionSentenceContext.window(selection: range, documentUTF16Length: document.utf16.count)
        XCTAssertEqual(window?.length, 2000)
        XCTAssertGreaterThan(window?.location ?? 0, 0)
        XCTAssertEqual(extract(document, selected: "ready"), "The project is ready for review.")
    }

    func testAmbiguousLowercaseContinuationAtWindowEdgeFallsBackToNil() {
        let document = String(repeating: "x", count: 1200) + ". The project is ready for review. " + String(repeating: "y", count: 1200) + "."
        XCTAssertNil(extract(document, selected: "ready"), "A tokenizer's uncertain sentence boundary must not turn a clipped tail into complete context")
    }

    func testClippedLongSentenceAndWhitespaceEdgesNeverMasqueradeAsFullSentence() {
        let document = "We are " + String(repeating: "extremely ", count: 160) + "ready " + String(repeating: "today ", count: 260) + "."
        XCTAssertNil(extract(document, selected: "ready"))
        for text in ["   clipped beginning ready for review. Another sentence.", "Previous sentence. We are ready for review   "] {
            let local = (text as NSString).range(of: "ready")
            XCTAssertNil(SelectionSentenceContext.sentence(selected: "ready", selection: NSRange(location: local.location + 40, length: local.length),
                windowText: text, windowRange: NSRange(location: 40, length: text.utf16.count), documentUTF16Length: text.utf16.count + 80))
        }
    }

    func testInvalidAndOverflowingRangesFailWithoutReadingOutsideTheSelection() {
        for range in [NSRange(location: -1, length: 5), NSRange(location: 10, length: 0), NSRange(location: 20, length: 5),
                      NSRange(location: Int.max - 2, length: 100), NSRange(location: 0, length: 2001)] {
            XCTAssertNil(SelectionSentenceContext.window(selection: range, documentUTF16Length: 20))
        }
        let text = "We are ready."
        let range = (text as NSString).range(of: "ready")
        XCTAssertNil(SelectionSentenceContext.sentence(selected: "other", selection: range, windowText: text,
            windowRange: NSRange(location: 0, length: text.utf16.count), documentUTF16Length: text.utf16.count))
        XCTAssertNil(SelectionSentenceContext.sentence(selected: "ready", selection: range, windowText: text,
            windowRange: NSRange(location: 0, length: text.utf16.count - 1), documentUTF16Length: text.utf16.count))
    }

    func testMarkerLengthIsCheckedBeforeAnyTextReadAndOutputIsValidated() {
        var reads = 0
        for length in [-1, 0, 2001, Int.max] {
            XCTAssertNil(SelectionSentenceContext.readBoundedSentence(selected: "ready", reportedUTF16Length: length) { reads += 1; return "We are ready." })
        }
        XCTAssertEqual(reads, 0, "Oversized or unavailable marker ranges must never trigger a string read")
        let sentence = "We are ready."
        XCTAssertEqual(SelectionSentenceContext.readBoundedSentence(selected: "ready", reportedUTF16Length: sentence.utf16.count) { reads += 1; return sentence }, sentence)
        XCTAssertEqual(reads, 1)
        XCTAssertNil(SelectionSentenceContext.readBoundedSentence(selected: "ready", reportedUTF16Length: sentence.utf16.count + 1) { sentence })
        XCTAssertNil(SelectionSentenceContext.boundedSentence("We are ready\0.", selected: "ready"))
        XCTAssertNil(SelectionSentenceContext.boundedSentence("A different sentence.", selected: "ready"))
        XCTAssertNil(SelectionSentenceContext.boundedSentence(String(repeating: "x", count: 2000) + "ready", selected: "ready"))
    }
}
