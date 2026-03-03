import Foundation
import PDFKit
import AppKit
import UniformTypeIdentifiers

/// Service for loading, chunking, and exporting documents
final class DocumentService {

    /// Supported document types
    enum DocumentType {
        case txt
        case pdf

        init?(url: URL) {
            switch url.pathExtension.lowercased() {
            case "txt", "text", "md":
                self = .txt
            case "pdf":
                self = .pdf
            default:
                return nil
            }
        }
    }

    /// Error types for document operations
    enum DocumentError: LocalizedError {
        case unsupportedFormat
        case tooLarge(Int)
        case readFailed(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return NSLocalizedString("document.unsupported_format", comment: "Unsupported document format")
            case .tooLarge(let chars):
                return String(format: NSLocalizedString("document.too_large", comment: "Document too large"), chars)
            case .readFailed(let detail):
                return detail
            case .exportFailed(let detail):
                return detail
            }
        }
    }

    /// Maximum document size in characters (~100 pages)
    static let maxDocumentSize = 500_000
    /// Target chunk size for translation
    static let chunkSize = 4000

    // MARK: - Load

    /// Load text content from a document URL
    func loadDocument(from url: URL) throws -> (text: String, type: DocumentType) {
        guard let type = DocumentType(url: url) else {
            throw DocumentError.unsupportedFormat
        }

        let text: String
        switch type {
        case .txt:
            text = try loadTextFile(url)
        case .pdf:
            text = try loadPDF(url)
        }

        guard text.count <= DocumentService.maxDocumentSize else {
            throw DocumentError.tooLarge(text.count)
        }

        return (text, type)
    }

    private func loadTextFile(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try other encodings
            if let data = try? Data(contentsOf: url),
               let str = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
                return str
            }
            throw DocumentError.readFailed(error.localizedDescription)
        }
    }

    private func loadPDF(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.readFailed("Failed to open PDF")
        }

        var pages: [String] = []
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string {
                pages.append(text)
            }
        }

        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentError.readFailed(
                NSLocalizedString("document.no_text", comment: "No extractable text found in PDF"))
        }
        return text
    }

    // MARK: - Chunking

    /// Split text into translation-sized chunks, respecting paragraph boundaries
    func chunkText(_ text: String, maxChunkSize: Int = DocumentService.chunkSize) -> [String] {
        // Split by double newlines (paragraph boundaries)
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // If single paragraph exceeds limit, split by sentences
            if trimmed.count > maxChunkSize {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                let sentences = splitIntoSentences(trimmed)
                for sentence in sentences {
                    if current.count + sentence.count + 1 > maxChunkSize && !current.isEmpty {
                        chunks.append(current)
                        current = sentence
                    } else {
                        current += (current.isEmpty ? "" : " ") + sentence
                    }
                }
                continue
            }

            // Try to add paragraph to current chunk
            let addition = (current.isEmpty ? "" : "\n\n") + trimmed
            if current.count + addition.count > maxChunkSize && !current.isEmpty {
                chunks.append(current)
                current = trimmed
            } else {
                current += addition
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        // Fallback: if no sentences detected, split by newlines
        if sentences.isEmpty {
            sentences = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - Export

    /// Export translated text to a file in the same format as the original
    func exportDocument(
        translatedText: String,
        originalURL: URL,
        type: DocumentType
    ) throws -> URL {
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let exportName = "\(baseName)_translated"

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = exportName

        switch type {
        case .txt:
            savePanel.allowedContentTypes = [.plainText]
            savePanel.nameFieldStringValue += ".txt"
        case .pdf:
            savePanel.allowedContentTypes = [.pdf]
            savePanel.nameFieldStringValue += ".pdf"
        }

        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            throw DocumentError.exportFailed("Export cancelled")
        }

        switch type {
        case .txt:
            try translatedText.write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            try exportAsPDF(translatedText, to: url)
        }

        return url
    }

    private func exportAsPDF(_ text: String, to url: URL) throws {
        let pageWidth: CGFloat = 612  // US Letter
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 72 // 1 inch
        let textWidth = pageWidth - margin * 2
        let textHeight = pageHeight - margin * 2

        let font = NSFont.systemFont(ofSize: 12)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: NSColor.black
        ]

        let attrString = NSAttributedString(string: text, attributes: attributes)

        // Use Core Text framesetter for proper multi-page layout
        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)
        let textLength = attrString.length
        var currentIndex = 0

        var pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            throw DocumentError.exportFailed("Failed to create PDF data consumer")
        }

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentError.exportFailed("Failed to create PDF context")
        }

        while currentIndex < textLength {
            ctx.beginPDFPage(nil)

            let textRect = CGRect(x: margin, y: margin, width: textWidth, height: textHeight)
            let path = CGPath(rect: textRect, transform: nil)

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(currentIndex, 0),
                path,
                nil
            )

            ctx.saveGState()
            // Flip for Core Text (CT uses bottom-left origin)
            ctx.translateBy(x: 0, y: pageHeight)
            ctx.scaleBy(x: 1.0, y: -1.0)

            CTFrameDraw(frame, ctx)
            ctx.restoreGState()

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            if visibleRange.length == 0 { ctx.endPDFPage(); break }
            currentIndex += visibleRange.length

            ctx.endPDFPage()
        }

        ctx.closePDF()
        try (pdfData as Data).write(to: url)
    }
}
