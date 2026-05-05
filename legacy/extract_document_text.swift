import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

struct ExtractionResult: Codable {
    let path: String
    let text: String
    let mode: String
    let error: String?
}

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif"]

func normalizeWhitespace(_ text: String) -> String {
    let parts = text
        .replacingOccurrences(of: "\u{00a0}", with: " ")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
    return parts.joined(separator: " ")
}

func ocrImage(_ cgImage: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["ko-KR", "en-US"]

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])

    let observations = request.results ?? []
    let lines = observations.compactMap { observation in
        observation.topCandidates(1).first?.string
    }
    return normalizeWhitespace(lines.joined(separator: "\n"))
}

func extractFromPDF(_ url: URL) throws -> (String, String) {
    guard let document = PDFDocument(url: url) else {
        throw NSError(domain: "extract_document_text", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to open PDF."
        ])
    }

    let directText = normalizeWhitespace(document.string ?? "")
    if directText.count >= 20 {
        return (directText, "pdf-text")
    }

    var ocrChunks: [String] = []
    for index in 0..<min(document.pageCount, 3) {
        guard let page = document.page(at: index) else {
            continue
        }
        let bounds = page.bounds(for: .mediaBox)
        let thumbnail = page.thumbnail(
            of: NSSize(width: max(bounds.width * 2.0, 1200), height: max(bounds.height * 2.0, 1600)),
            for: .mediaBox
        )
        if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let text = try ocrImage(cgImage)
            if !text.isEmpty {
                ocrChunks.append(text)
            }
        }
    }

    let ocrText = normalizeWhitespace(ocrChunks.joined(separator: "\n"))
    if !ocrText.isEmpty {
        return (ocrText, "pdf-ocr")
    }

    return (directText, directText.isEmpty ? "pdf-empty" : "pdf-text-short")
}

func extractFromImage(_ url: URL) throws -> (String, String) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw NSError(domain: "extract_document_text", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Failed to open image source."
        ])
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "extract_document_text", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to decode image."
        ])
    }
    let text = try ocrImage(cgImage)
    return (text, "image-ocr")
}

func parsePaths(arguments: [String]) throws -> [String] {
    if let index = arguments.firstIndex(where: { $0.hasPrefix("--path-file=") }) {
        let path = String(arguments[index].dropFirst("--path-file=".count))
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return content
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    return arguments.filter { !$0.hasPrefix("--") }
}

let args = Array(CommandLine.arguments.dropFirst())
let paths: [String]

do {
    paths = try parsePaths(arguments: args)
} catch {
    let result = [ExtractionResult(path: "", text: "", mode: "error", error: error.localizedDescription)]
    let data = try JSONEncoder().encode(result)
    FileHandle.standardOutput.write(data)
    exit(1)
}

if paths.isEmpty {
    fputs("Usage: swift extract_document_text.swift [--path-file=/tmp/paths.txt] <file1> [<file2> ...]\n", stderr)
    exit(1)
}

var results: [ExtractionResult] = []

for rawPath in paths {
    let url = URL(fileURLWithPath: rawPath)
    let ext = url.pathExtension.lowercased()

    do {
        if ext == "pdf" {
            let (text, mode) = try extractFromPDF(url)
            results.append(ExtractionResult(path: rawPath, text: text, mode: mode, error: nil))
        } else if imageExtensions.contains(ext) {
            let (text, mode) = try extractFromImage(url)
            results.append(ExtractionResult(path: rawPath, text: text, mode: mode, error: nil))
        } else {
            results.append(ExtractionResult(path: rawPath, text: "", mode: "unsupported", error: nil))
        }
    } catch {
        results.append(ExtractionResult(path: rawPath, text: "", mode: "error", error: error.localizedDescription))
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
let output = try encoder.encode(results)
FileHandle.standardOutput.write(output)
