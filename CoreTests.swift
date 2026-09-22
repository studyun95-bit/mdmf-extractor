import Foundation
import CommonCrypto
import PDFKit

/// Compile with Extractor.swift and run with: CoreTests fixture.mdmf expected.pdf
@main
struct CoreTests {
    static var assertions = 0

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(message: message) }
        assertions += 1
    }

    static func rejects(_ name: String, _ action: () throws -> Void) throws {
        do {
            try action()
        } catch is ExtractionError {
            assertions += 1
            return
        }
        throw TestFailure(message: "Expected safe rejection: \(name)")
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw TestFailure(message: "Usage: CoreTests fixture.mdmf expected.pdf")
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw = try Data(contentsOf: fixtureURL)
        let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let decoded = try MDMFExtractor.decode(raw)
        try require(decoded == expected, "Real fixture must exactly match the independently extracted PDF")
        try require(PDFDocument(data: decoded)?.pageCount == 1, "Real fixture has one page")
        // Sliced Foundation Data can have a non-zero startIndex.
        var prefixed = Data([0x7f])
        prefixed.append(raw)
        try require(MDMFExtractor.decode(prefixed.dropFirst()) == expected, "Non-zero Data index")

        let header = try crypt(raw.subdata(in: 22..<2249), operation: CCOperation(kCCDecrypt),
                               key: Data("dONGHwaMAnSeMfan".utf8))
        let metadataLength = Int(String(decoding: raw[2249..<2259], as: UTF8.self))!
        let pdfStart = 2259 + metadataLength + 20
        let pdfEnd = pdfStart + expected.count
        for length in [0, 9, 21, 22, 2248, 2258, 2259 + metadataLength - 1, pdfStart - 1, pdfEnd - 1] {
            try rejects("truncation at \(length)") { _ = try MDMFExtractor.decode(Data(raw.prefix(length))) }
        }

        var changed = raw
        changed[0] = 0x21
        try rejects("unknown signature") { _ = try MDMFExtractor.decode(changed) }
        changed = raw
        changed.replaceSubrange(20..<22, with: Data("12".utf8))
        try rejects("unknown version") { _ = try MDMFExtractor.decode(changed) }
        changed = raw
        changed.replaceSubrange(10..<20, with: Data("0000002228".utf8))
        try rejects("unknown header size") { _ = try MDMFExtractor.decode(changed) }
        changed = raw
        changed[10] = 0x2d
        try rejects("negative header length") { _ = try MDMFExtractor.decode(changed) }
        changed = raw
        changed.replaceSubrange(2249..<2259, with: Data("9999999999".utf8))
        try rejects("metadata exceeds container") { _ = try MDMFExtractor.decode(changed) }
        changed = raw
        changed[2250] = 0x61
        try rejects("non-decimal metadata length") { _ = try MDMFExtractor.decode(changed) }

        for (name, offset, text) in [
            ("oversized PDF length", 0, "9999999999"),
            ("empty PDF length", 0, "0000000000"),
            ("non-decimal PDF length", 0, "000000000x"),
            ("unsupported secondary payload", 10, "0000000001"),
            ("unsupported record length", 404, "0000000021")
        ] {
            var modifiedHeader = header
            modifiedHeader.replaceSubrange(offset..<(offset + 10), with: Data(text.utf8))
            changed = try replacingHeader(raw, with: modifiedHeader)
            try rejects(name) { _ = try MDMFExtractor.decode(changed) }
        }

        changed = raw
        changed[pdfStart] ^= 0xff
        try rejects("corrupt PDF payload") { _ = try MDMFExtractor.decode(changed) }
        var badPDF = expected
        badPDF.replaceSubrange(0..<5, with: Data("BROKE".utf8))
        changed = raw
        changed.replaceSubrange(pdfStart..<pdfEnd,
                                with: try crypt(badPDF, operation: CCOperation(kCCEncrypt),
                                                key: header.subdata(in: 1029..<1045)))
        try rejects("invalid decrypted PDF signature") { _ = try MDMFExtractor.decode(changed) }
        badPDF = expected
        if let eofRange = badPDF.range(of: Data("%%EOF".utf8), options: .backwards) {
            badPDF.replaceSubrange(eofRange, with: Data("BROKE".utf8))
        }
        changed = raw
        changed.replaceSubrange(pdfStart..<pdfEnd,
                                with: try crypt(badPDF, operation: CCOperation(kCCEncrypt),
                                                key: header.subdata(in: 1029..<1045)))
        try rejects("missing EOF marker") { _ = try MDMFExtractor.decode(changed) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MDMFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("공문 (테스트) 테스트.mdmf")
        try raw.write(to: source)
        let result = try MDMFExtractor.extract(source)
        try require(result.pageCount == 1, "Extraction returns page count")
        try require(result.inputURL == source, "Extraction returns input URL")
        try require(result.outputURL.lastPathComponent == "공문 (테스트) 테스트.pdf", "Korean filename preserved")
        try require(Data(contentsOf: result.outputURL) == expected, "Saved PDF is exact")
        try require(Data(contentsOf: source) == raw, "Source is unchanged")

        let sentinel = Data("An existing PDF must never be replaced.".utf8)
        try sentinel.write(to: result.outputURL)
        let second = try MDMFExtractor.extract(source)
        try require(second.outputURL.lastPathComponent == "공문 (테스트) 테스트 (2).pdf", "Collision gets suffix")
        try require(Data(contentsOf: result.outputURL) == sentinel, "Existing output preserved")
        try require(Data(contentsOf: second.outputURL) == expected, "Second output is exact")

        let alternate = directory.appendingPathComponent("다른 폴더")
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: false)
        let symlinkOutput = alternate.appendingPathComponent("공문 (테스트) 테스트.pdf")
        try FileManager.default.createSymbolicLink(at: symlinkOutput, withDestinationURL: source)
        let withSymlink = try MDMFExtractor.extract(source, outputDirectory: alternate)
        try require(withSymlink.outputURL.lastPathComponent == "공문 (테스트) 테스트 (2).pdf", "Symlink collision skipped")
        try require(Data(contentsOf: source) == raw, "Symlink destination unchanged")

        let invalidSource = directory.appendingPathComponent("손상된 공문.mdmf")
        try changed.write(to: invalidSource)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        try rejects("no partial PDF on invalid input") { _ = try MDMFExtractor.extract(invalidSource) }
        try require(FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before,
                    "Invalid input creates no output")
        try rejects("missing source") { _ = try MDMFExtractor.extract(directory.appendingPathComponent("missing.mdmf")) }
        try rejects("directory input") { _ = try MDMFExtractor.extract(directory) }
        try rejects("missing output folder") {
            _ = try MDMFExtractor.extract(source, outputDirectory: directory.appendingPathComponent("missing"))
        }

        let oversized = directory.appendingPathComponent("oversized.mdmf")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let sparse = try FileHandle(forWritingTo: oversized)
        try sparse.truncate(atOffset: UInt64(MDMFExtractor.maximumInputSize + 1))
        try sparse.close()
        try rejects("oversized file rejected before loading") { _ = try MDMFExtractor.extract(oversized) }
        print("PASS: \(assertions) assertions; real PDF matches exactly; malformed files rejected; no overwrite.")
    }

    static func replacingHeader(_ raw: Data, with header: Data) throws -> Data {
        var result = raw
        result.replaceSubrange(22..<2249, with: try crypt(header, operation: CCOperation(kCCEncrypt),
                                                         key: Data("dONGHwaMAnSeMfan".utf8)))
        return result
    }

    /// Test-only fixture mutation helper; tests assert against an independently extracted PDF.
    static func crypt(_ data: Data, operation: CCOperation, key: Data) throws -> Data {
        var output = Data()
        let iv = [UInt8](repeating: 0, count: 16)
        for offset in stride(from: 0, to: data.count, by: 256) {
            let chunk = data.subdata(in: offset..<min(offset + 256, data.count))
            let count = chunk.count / 16 * 16
            var buffer = [UInt8](repeating: 0, count: max(16, count))
            var written = 0
            if count > 0 {
                let status = chunk.withUnsafeBytes { source in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, key.count, iv,
                                source.baseAddress, count, &buffer, buffer.count, &written)
                    }
                }
                guard status == kCCSuccess, written == count else { throw TestFailure(message: "Fixture encryption failed") }
                output.append(contentsOf: buffer.prefix(written))
            }
            output.append(chunk.suffix(chunk.count - count))
        }
        return output
    }

    struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
