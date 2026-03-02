import Vision
import AppKit

/// Service for OCR text recognition from images using Vision framework
final class OCRService {
    static let shared = OCRService()
    private init() {}

    /// Recognize text from an NSImage using Vision framework
    /// - Parameters:
    ///   - image: The image to recognize text from
    ///   - languages: Optional language hints for better recognition
    /// - Returns: Recognized text string
    func recognizeText(from image: NSImage, languages: [String]? = nil) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                // Sort observations by vertical position (top to bottom)
                let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }

                // Extract text from each observation
                let lines = sorted.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }

                let result = lines.joined(separator: "\n")
                continuation.resume(returning: result)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            // Set recognition languages if provided
            if let languages = languages, !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
            }
        }
    }

    /// Check if the clipboard contains an image
    static func clipboardContainsImage() -> Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.canReadItem(withDataConformingToTypes: NSImage.imageTypes)
    }

    /// Get image from clipboard
    static func imageFromClipboard() -> NSImage? {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) else {
            return nil
        }
        return NSImage(data: data)
    }

    /// Load image from file URL
    static func imageFromFile(_ url: URL) -> NSImage? {
        return NSImage(contentsOf: url)
    }
}

// MARK: - Errors

enum OCRError: LocalizedError {
    case invalidImage
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid image for OCR"
        case .recognitionFailed(let reason):
            return "OCR failed: \(reason)"
        }
    }
}
