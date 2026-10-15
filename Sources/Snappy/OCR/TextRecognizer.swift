import Vision

/// Offline text recognition via Vision (`RecognizeTextRequest`),
/// English + German.
enum TextRecognizer {
    static let recognitionLanguages = [
        Locale.Language(identifier: "en-US"),
        Locale.Language(identifier: "de-DE"),
    ]

    /// Runs accurate-mode recognition (Vision performs it off-main) and returns
    /// the assembled text (top-to-bottom, line breaks preserved, trimmed).
    /// Empty string means no text was recognized.
    static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages
        let observations = try await request.perform(on: image)
        let fragments = observations.compactMap { observation in
            observation.topCandidates(1).first.map {
                TextObservation(string: $0.string, boundingBox: observation.boundingBox.cgRect)
            }
        }
        return TextAssembler.joinedText(from: fragments)
    }
}
