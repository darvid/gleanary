import AppKit
import Foundation
import PDFKit
import Vision

private struct PDFPageContent {
    var blocks: [ContentBlock] = []
    var warnings: [String] = []
    var partial = false
}

actor PDFExtractor {
    func extract(
        _ data: Data,
        name: String,
        url: URL?,
        progress: @Sendable (String) async throws -> Void = { _ in }
    ) async throws -> CapturedDocument {
        guard let pdf = PDFDocument(data: data) else { throw CaptureError.invalidPDF }
        guard !pdf.isLocked else { throw CaptureError.lockedPDF }
        guard pdf.pageCount > 0 else { throw CaptureError.noContent }
        guard pdf.pageCount <= CaptureLimits.pdfPages else { throw CaptureError.tooManyPages }
        var result =
            PDFPageContent(
                warnings: [
                    "Figures and equations may require the original PDF. Reconstructed text is not a visual interpretation.",
                ]
            )
        for index in 0 ..< pdf.pageCount {
            try Task.checkCancellation()
            try await progress("Reading PDF text, page \(index + 1) of \(pdf.pageCount)")
            guard let page = pdf.page(at: index) else {
                result.partial = true
                result.warnings.append("Page \(index + 1) could not be read.")
                continue
            }
            let extracted = try await extractPage(
                page,
                number: index + 1,
                total: pdf.pageCount,
                progress: progress
            )
            result.blocks += extracted.blocks
            result.warnings += extracted.warnings
            result.partial = result.partial || extracted.partial
        }
        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        return CapturedDocument(
            title: title?.isEmpty == false ? title ?? name : name,
            authors: author.map { [$0] } ?? [],
            sourceURL: url,
            coverage: result.partial ? .partial : .document,
            warnings: result.warnings,
            blocks: result.blocks
        )
    }

    private func extractPage(
        _ page: PDFPage, number: Int, total: Int,
        progress: @Sendable (String) async throws -> Void
    ) async throws -> PDFPageContent {
        let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let native = ContentBlock(
            kind: .paragraph,
            markdown: text,
            text: text,
            page: number,
            method: "pdfkit"
        )
        if text.count >= 80 {
            // Layout alone is not a reason to replace existing text with slower, lossy OCR.
            let warnings = Self.needsLayout(page, text: text)
                ?
                [
                    "Embedded PDF text was preserved. Multi-column or tabular reading order may need review against the original.",
                ]
                : []
            return PDFPageContent(blocks: [native], warnings: warnings)
        }
        try await progress("Running OCR on page \(number) of \(total)")
        do {
            let image = try Self.render(page)
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.automaticallyDetectLanguage = true
            request.textRecognitionOptions.useLanguageCorrection = false
            request.barcodeDetectionOptions.enabled = false
            let observations = try await request.perform(on: image)
            try Task.checkCancellation()
            var result = Self.recognizedContent(observations, page: number)
            // A much shorter OCR result must not replace a substantial native text layer.
            if !text.isEmpty, result.blocks.map(\.text).joined().count < text.count / 2 {
                result.blocks = [Self.fallback(text, page: number)]
                result.partial = true
                result.warnings
                    .append(
                        "Page \(number) retained its native text; reading order may need review."
                    )
            } else if result.blocks.isEmpty {
                result.partial = true
                result.warnings.append("No readable text was found on page \(number).")
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return PDFPageContent(
                blocks: text.isEmpty ? [] : [Self.fallback(text, page: number)],
                warnings: ["Layout/OCR failed on page \(number)."],
                partial: true
            )
        }
    }

    private static func recognizedContent(
        _ observations: [DocumentObservation],
        page: Int
    ) -> PDFPageContent {
        var result = PDFPageContent()
        for observation in observations {
            let document = observation.document
            let structuredRegions = Set(document.tables.flatMap(\.rows).flatMap(\.self)
                .map(\.content.boundingRegion) + document.lists.flatMap(\.items)
                .map(\.content.boundingRegion))
            var blocks: [ContentBlock] = document.paragraphs.compactMap { paragraph in
                let value = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      !structuredRegions.contains(paragraph.boundingRegion) else { return nil }
                return ContentBlock(
                    kind: .paragraph,
                    markdown: value,
                    text: value,
                    page: page,
                    method: "vision-document"
                )
            }
            for list in document.lists {
                let text = list.items.map { "\($0.markerString) \($0.content.text.transcript)" }
                    .joined(separator: "\n")
                blocks.append(ContentBlock(
                    kind: .list,
                    markdown: text,
                    text: text,
                    page: page,
                    method: "vision-list"
                ))
                result.warnings
                    .append(
                        "Reconstructed lists may appear after paragraph text. Verify reading order against the original."
                    )
            }
            for table in document.tables {
                let rows = table.rows.map { row in row.map(\.content.text.transcript) }
                blocks.append(ContentBlock(
                    kind: .table,
                    markdown: tableMarkdown(rows),
                    text: rows.map { $0.joined(separator: "\t") }
                        .joined(separator: "\n"),
                    page: page,
                    method: "vision-table"
                ))
                result.warnings
                    .append(
                        "Tables use generated column labels and may appear after page text. Verify cell layout against the original."
                    )
            }
            if blocks.isEmpty, !document.text.transcript.isEmpty {
                let value = document.text.transcript
                blocks.append(ContentBlock(
                    kind: .paragraph,
                    markdown: value,
                    text: value,
                    page: page,
                    method: "vision-document"
                ))
            }
            // DocumentObservation.confidence can be zero even for correct text; use OCR candidates.
            if document.text.lines
                .contains(where: { ($0.topCandidates(1).first?.confidence ?? 0) < 0.5 })
            {
                result.partial = true
                result.warnings.append("Page \(page) has low OCR confidence; review the original.")
            }
            result.blocks += blocks
        }
        return result
    }

    private static func fallback(_ text: String, page: Int) -> ContentBlock {
        ContentBlock(
            kind: .paragraph,
            markdown: text,
            text: text,
            page: page,
            method: "pdfkit-fallback"
        )
    }

    private static func needsLayout(_ page: PDFPage, text: String) -> Bool {
        let width = page.bounds(for: .mediaBox).width
        let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
        let narrow = lines.filter { $0.bounds(for: page).width < width * 0.48 }
        let right = narrow.filter { $0.bounds(for: page).minX > width * 0.45 }
        return (narrow.count >= 6 && right.count >= 3) || text.contains("\t") || text
            .contains("   ")
    }

    private static func render(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              let reference = page.pageRef else { throw CaptureError.invalidPDF }
        let scale = 2200 / max(bounds.width, bounds.height)
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        else { throw CaptureError.extractionFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGPDFPage's fitting transform does not upscale. Scale the raster context explicitly.
        context.scaleBy(x: scale, y: scale)
        context.concatenate(reference.getDrawingTransform(
            .mediaBox,
            rect: CGRect(origin: .zero, size: bounds.size),
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw CaptureError.extractionFailed }
        return image
    }

    private static func tableMarkdown(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        func row(_ cells: [String]) -> String {
            "| " + (0 ..< width).map { index in
                index < cells.count ? cells[index].replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(
                        of: "\n",
                        with: " "
                    ) : ""
            }.joined(separator: " | ") + " |"
        }
        return ([
            row((1 ... width).map { "Column \($0)" }),
            row(Array(repeating: "---", count: width)),
        ] + rows.map(row)).joined(separator: "\n")
    }
}
