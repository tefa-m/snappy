import CoreGraphics
import Foundation

/// One recognized text fragment with its Vision bounding box
/// (normalized 0–1, origin bottom-left, y grows up).
struct TextObservation: Sendable {
    let string: String
    let boundingBox: CGRect
}

/// PURE assembly of OCR observations into clipboard text — unit-tested.
enum TextAssembler {
    /// Joins observations top-to-bottom into lines. Fragments whose boxes
    /// overlap vertically by at least half the smaller height belong to the
    /// same visual line and are joined left-to-right with a space; lines are
    /// separated by newlines. Trailing whitespace is trimmed.
    static func joinedText(from observations: [TextObservation]) -> String {
        let sorted = observations
            .filter { !$0.string.isEmpty }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var lines: [(box: CGRect, fragments: [TextObservation])] = []
        for observation in sorted {
            if let index = lines.indices.last,
               sameLine(lines[index].box, observation.boundingBox) {
                lines[index].fragments.append(observation)
                lines[index].box = lines[index].box.union(observation.boundingBox)
            } else {
                lines.append((observation.boundingBox, [observation]))
            }
        }

        return lines
            .map { line in
                let text = line.fragments
                    .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .map(\.string)
                    .joined(separator: " ")
                return trimmingTrailingWhitespace(text)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Single-line preview for the "Text copied" notification banner.
    static func preview(of text: String, maxLength: Int = 80) -> String {
        let collapsed = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        return collapsed.prefix(maxLength) + "…"
    }

    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= 0.5 * min(a.height, b.height)
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var text = text
        while let last = text.unicodeScalars.last,
              CharacterSet.whitespaces.contains(last) {
            text.unicodeScalars.removeLast()
        }
        return text
    }
}
