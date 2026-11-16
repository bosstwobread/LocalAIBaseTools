import Foundation
import NaturalLanguage

/// Text selected by the user, with an optional bounded sentence captured only
/// when a lexical word is selected. The sentence is context, never replacement text.
public struct CapabilitySelectionInput: Equatable, Sendable {
    public let text: String
    public let sentence: String?

    public init(text: String, sentence: String? = nil) {
        self.text = text
        self.sentence = sentence
    }
}

/// Pure UTF-16 range planning/extraction. AX offsets are UTF-16 code units,
/// which differ from Swift Character offsets around emoji and combining marks.
enum SelectionSentenceContext {
    static let maximumUTF16 = 2000
    static let maximumUTF8 = 8000

    static func isSingleWord(_ selected: String) -> Bool {
        let word = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.utf16.count <= 128 else { return false }
        let scalars = Array(word.unicodeScalars)
        let connectors: Set<UInt32> = [0x27, 0x2019, 0x02BC, 0x2D, 0x2010, 0x2011]
        var hasLetter = false
        var afterConnector = true
        for scalar in scalars {
            if connectors.contains(scalar.value) {
                guard !afterConnector else { return false }
                afterConnector = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                hasLetter = true; afterConnector = false
            case .decimalNumber, .letterNumber, .otherNumber:
                afterConnector = false
            case .nonspacingMark, .spacingMark, .enclosingMark:
                guard !afterConnector else { return false }
            default: return false
            }
        }
        guard hasLetter, !afterConnector else { return false }
        let spacelessScript = scalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value) ||
            (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) ||
            (0x0E00...0x0EFF).contains($0.value) || (0x1000...0x109F).contains($0.value) || (0x1780...0x17FF).contains($0.value)
        }
        if spacelessScript {
            guard word.count <= 8 else { return false }
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = word
            var ranges: [Range<String.Index>] = []
            tokenizer.enumerateTokens(in: word.startIndex..<word.endIndex) { range, _ in
                ranges.append(range)
                return ranges.count < 2
            }
            guard ranges.count == 1, ranges[0] == (word.startIndex..<word.endIndex) else { return false }
        }
        return true
    }

    static func window(selection: NSRange, documentUTF16Length: Int) -> NSRange? {
        guard selection.location >= 0, selection.length > 0, selection.length <= maximumUTF16,
              documentUTF16Length >= 0, selection.location <= documentUTF16Length,
              selection.length <= documentUTF16Length - selection.location else { return nil }
        let margin = (maximumUTF16 - selection.length) / 2
        let start = max(0, selection.location - margin)
        let length = min(maximumUTF16, documentUTF16Length - start)
        return NSRange(location: start, length: length)
    }

    static func sentence(selected: String, selection: NSRange, windowText: String,
                         windowRange: NSRange, documentUTF16Length: Int) -> String? {
        guard isSingleWord(selected), windowRange.location >= 0, windowRange.length <= maximumUTF16,
              windowText.utf16.count == windowRange.length, windowRange.location <= documentUTF16Length,
              windowRange.length <= documentUTF16Length - windowRange.location,
              selection.location >= windowRange.location,
              selection.length == selected.utf16.count,
              selection.location - windowRange.location <= windowRange.length,
              selection.length <= windowRange.length - (selection.location - windowRange.location) else { return nil }
        let text = windowText as NSString
        let relative = NSRange(location: selection.location - windowRange.location, length: selection.length)
        guard text.substring(with: relative) == selected else { return nil }
        let word = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordOffset = (selected as NSString).range(of: word)
        let wordRange = NSRange(location: relative.location + wordOffset.location, length: wordOffset.length)
        var result: String?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.bySentences, .substringNotRequired]) { _, range, enclosing, stop in
            guard wordRange.location >= range.location, NSMaxRange(wordRange) <= NSMaxRange(range) else { return }
            stop.pointee = true
            // A tokenizer labels edge fragments as sentences too. Accept those
            // only at a verified document edge, never at our clipped window edge.
            let clippedLeft = enclosing.location == 0 || text.substring(to: range.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let clippedRight = NSMaxRange(enclosing) == text.length || text.substring(from: NSMaxRange(range)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !clippedLeft || windowRange.location == 0,
                  !clippedRight || NSMaxRange(windowRange) == documentUTF16Length else { return }
            result = boundedSentence(text.substring(with: range), selected: selected)
        }
        return result
    }

    static func boundedSentence(_ sentence: String, selected: String, reportedUTF16Length: Int? = nil) -> String? {
        if let reportedUTF16Length, reportedUTF16Length != sentence.utf16.count { return nil }
        let result = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSingleWord(selected), !result.isEmpty, result.utf16.count <= maximumUTF16,
              result.utf8.count <= maximumUTF8, !result.contains("\0"), result.contains(word) else { return nil }
        return result
    }

    static func readBoundedSentence(selected: String, reportedUTF16Length: Int, read: () -> String?) -> String? {
        guard isSingleWord(selected), reportedUTF16Length > 0, reportedUTF16Length <= maximumUTF16,
              let text = read() else { return nil }
        return boundedSentence(text, selected: selected, reportedUTF16Length: reportedUTF16Length)
    }
}

struct TextSelection: Equatable, Sendable {
    let text: String
    let sourcePID: Int32
    let rangeLocation: Int
    let rangeLength: Int
    /// AppKit global coordinates, in screen points.
    let bounds: CGRect
}

/// Selection changes invalidate every in-flight result, including repeated text
/// selected in a different app or at a different location.
struct SelectionState {
    private(set) var selection: TextSelection?
    private(set) var generation: UInt64 = 0
    private(set) var dismissed = false

    @discardableResult
    mutating func observe(_ value: TextSelection?) -> Bool {
        guard value != selection else { return false }
        generation &+= 1
        selection = value
        // AX can briefly return no selection, cached text, or different fallback
        // bounds after an ordinary click. Observations invalidate old work but
        // cannot undo a dismissal; only an explicit selection gesture can.
        return true
    }

    mutating func dismiss() {
        generation &+= 1
        dismissed = true
    }

    /// Only real selection gestures rearm a dismissed selection. Timer reads,
    /// geometry changes, and intermittent AX availability cannot bring it back.
    mutating func rearmAfterSelectionGesture() {
        guard dismissed else { return }
        generation &+= 1
        selection = nil
        dismissed = false
    }

    var canTranslate: Bool { selection != nil && !dismissed }

    func acceptsResult(for token: UInt64) -> Bool {
        canTranslate && token == generation
    }
}

enum FloatingGeometry {
    /// AX uses a top-left origin on the main screen; AppKit uses bottom-left.
    /// Other displays may have negative x/y, so never use the union's height.
    static func appKitRect(fromAccessibility rect: CGRect, mainScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func screen(for anchor: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        if let containing = visibleFrames.first(where: { $0.contains(center) }) { return containing }
        return visibleFrames.max { lhs, rhs in
            intersectionArea(lhs, anchor) < intersectionArea(rhs, anchor)
        }
    }

    static func frame(size: CGSize, near anchor: CGRect, in visibleFrame: CGRect, gap: CGFloat = 7) -> CGRect {
        let inset = visibleFrame.insetBy(dx: 6, dy: 6)
        let width = min(size.width, max(1, inset.width))
        let height = min(size.height, max(1, inset.height))
        let above = anchor.maxY + gap
        let below = anchor.minY - gap - height
        let aboveRoom = inset.maxY - anchor.maxY - gap
        let belowRoom = anchor.minY - inset.minY - gap
        let preferredY = aboveRoom >= height || aboveRoom >= belowRoom ? above : below
        return CGRect(
            x: clamp(anchor.minX, lower: inset.minX, upper: inset.maxX - width),
            y: clamp(preferredY, lower: inset.minY, upper: inset.maxY - height),
            width: width, height: height
        )
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
