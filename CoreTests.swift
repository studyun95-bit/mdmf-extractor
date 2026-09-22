import Foundation
import CommonCrypto
import PDFKit
import CoreFoundation
import zlib

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
        guard [3, 5].contains(CommandLine.arguments.count) else {
            throw TestFailure(message: "Usage: CoreTests fixture.mdmf expected.pdf [attachments.mdmf expected-attachments-directory]")
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
        try attachmentTests(base: Data(raw.prefix(pdfEnd)), header: header, expectedPDF: expected,
                            directory: directory)
        if CommandLine.arguments.count == 5 {
            let sample = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
            let archive = try MDMFExtractor.decodeArchive(sample)
            let expectedDirectory = URL(fileURLWithPath: CommandLine.arguments[4])
            try require(!archive.attachments.isEmpty, "Real attachment sample contains attachments")
            for attachment in archive.attachments {
                try require(attachment.data == Data(contentsOf: expectedDirectory.appendingPathComponent(attachment.fileName)),
                            "Real attachment bytes match independently recovered file")
            }
        }
        print("PASS: \(assertions) assertions; PDF and attachments match; malformed containers rejected; safe writes verified.")
    }

    static func attachmentTests(base: Data, header: Data, expectedPDF: Data, directory: URL) throws {
        let first = Data((0..<60_137).map { UInt8(truncatingIfNeeded: ($0 * 29) ^ ($0 >> 8)) })
        let second = Data("A generic attachment keeps its bytes.\0\n".utf8)
        let names = ["붙임 한글.hwp", "둘째.hwpx", "empty.bin"]
        let contents = [first, second, Data()]
        let fixture = try attached(base: base, header: header, names: names, contents: contents)
        let archive = try MDMFExtractor.decodeArchive(fixture)
        try require(archive.pdf == expectedPDF, "Adding attachments preserves PDF exactly")
        try require(archive.attachments.map { $0.fileName } == names, "CP949 names decoded in order")
        try require(archive.attachments.map { $0.data } == contents, "Multiblock and empty attachments decode exactly")
        try require(MDMFExtractor.decodeArchive(base).attachments.isEmpty, "Trailer is optional")
        try require(MDMFExtractor.decode(fixture) == expectedPDF, "PDF API remains compatible")
        var indexed = Data([0x11]); indexed.append(fixture)
        try require(MDMFExtractor.decodeArchive(indexed.dropFirst()).attachments.map { $0.data } == contents,
                    "Attachment parsing accepts non-zero Data startIndex")

        for invalidName in ["../outside.hwp", "..", ".", "/absolute.hwp", "folder\\file.hwp", "disk:file.hwp", "line\nfile.hwp", ""] {
            try rejects("unsafe filename \(invalidName)") {
                _ = try MDMFExtractor.decodeArchive(attached(base: base, header: header,
                                                            names: [invalidName], contents: [second]))
            }
        }
        var unknown = base; unknown.append(Data("UNKNOWN".utf8))
        try rejects("unknown trailing data") { _ = try MDMFExtractor.decodeArchive(unknown) }
        try rejects("truncated trailer") { _ = try MDMFExtractor.decodeArchive(fixture.dropLast()) }
        try rejects("trailing bytes outside trailer") { _ = try MDMFExtractor.decodeArchive(fixture + Data([0])) }
        let metadataChanges: [(String, (inout Data) -> Void)] = [
            ("nonterminated filename", { (meta: inout Data) in meta.replaceSubrange(276..<532, with: Data(repeating: 65, count: 256)) }),
            ("count mismatch", { (meta: inout Data) in meta.replaceSubrange(4..<8, with: be(2)) }),
            ("too many attachments", { (meta: inout Data) in meta.replaceSubrange(4..<8, with: be(1_001)) }),
            ("text size overflow", { (meta: inout Data) in meta.replaceSubrange(0..<4, with: be(0xffffffff)) }),
            ("offset overlap or gap", { (meta: inout Data) in meta.replaceSubrange(540..<544, with: be(1)) }),
            ("stored data truncated", { (meta: inout Data) in meta.replaceSubrange(536..<540, with: be(0xffffffff)) }),
            ("output limit", { (meta: inout Data) in meta.replaceSubrange(532..<536, with: be(MDMFExtractor.maximumInputSize)) }),
            ("size mismatch", { (meta: inout Data) in meta.replaceSubrange(532..<536, with: be(2)) })
        ]
        for (label, change) in metadataChanges {
            try rejects(label) {
                _ = try MDMFExtractor.decodeArchive(attached(base: base, header: header, names: ["test.bin"],
                                                            contents: [second], mutateMetadata: change))
            }
        }
        let streamChanges: [(String, (inout Data) -> Void)] = [
            ("wrong embedded size", { (stream: inout Data) in stream.replaceSubrange(0..<4, with: be(3)) }),
            ("zero compressed block", { (stream: inout Data) in stream.replaceSubrange(4..<8, with: be(0)) }),
            ("oversized compressed block", { (stream: inout Data) in stream.replaceSubrange(4..<8, with: be(45_001)) }),
            ("corrupt compressed stream", { (stream: inout Data) in stream[8] ^= 0xff }),
            ("zlib trailing junk", { (stream: inout Data) in
                let size = stream.count - 8; stream.append(0x77); stream.replaceSubrange(4..<8, with: be(size + 1))
            }),
            ("truncated compressed stream", { (stream: inout Data) in stream.removeLast() })
        ]
        for (label, mutate) in streamChanges {
            try rejects(label) {
                _ = try MDMFExtractor.decodeArchive(attached(base: base, header: header, names: ["test.bin"],
                                                            contents: [second], mutateStream: mutate))
            }
        }
        try rejects("missing NUL sentinel") {
            _ = try MDMFExtractor.decodeArchive(attached(base: base, header: header, names: ["test.bin"],
                                                        contents: [second], sentinel: 1))
        }
        try rejects("inflated block over 30001") {
            _ = try MDMFExtractor.decodeArchive(attached(base: base, header: header, names: ["test.bin"],
                                                        contents: [Data(repeating: 65, count: 30_001)], chunkSize: 30_001))
        }
        do {
            _ = try MDMFExtractor.decodeArchive(attached(base: base, header: header, names: ["a", "b"],
                contents: [first, Data()], mutateMetadata: { meta in
                    meta.replaceSubrange(800..<804,
                                         with: be(MDMFExtractor.maximumInputSize - expectedPDF.count - first.count + 1))
                }))
            throw TestFailure(message: "Expected summed output cap")
        } catch ExtractionError.tooLarge {
            assertions += 1
        }

        let outputDirectory = directory.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("attachment-source.mdmf")
        try fixture.write(to: source)
        let saved = try MDMFExtractor.extract(source, outputDirectory: outputDirectory)
        try require(saved.attachmentURLs.map { $0.lastPathComponent } == names, "All attachment names saved")
        try require(saved.outputURLs.count == 4, "Result lists PDF and every attachment")
        try require(try saved.attachmentURLs.map { try Data(contentsOf: $0) } == contents, "Saved attachment bytes exact")
        let repeatSave = try MDMFExtractor.extract(source, outputDirectory: outputDirectory)
        try require(repeatSave.attachmentURLs[0].lastPathComponent == "붙임 한글 (2).hwp", "Attachment collision preserves extension")
        try require(try saved.attachmentURLs.map { try Data(contentsOf: $0) } == contents, "Attachment collisions never overwrite")
        let sameNames = try attached(base: base, header: header, names: ["duplicate.bin", "duplicate.bin"], contents: [first, second])
        try sameNames.write(to: source)
        let duplicates = try MDMFExtractor.extract(source, outputDirectory: outputDirectory)
        try require(duplicates.attachmentURLs.map { $0.lastPathComponent } == ["duplicate.bin", "duplicate (2).bin"],
                    "Duplicate names inside one container get distinct files")

        // Extensions are opaque: archive contents are saved as-is, never recursively unpacked.
        // These are small format-shaped fixtures, not claims that Excel/image apps can open them.
        let zipBytes = Data(base64Encoded: "UEsDBBQAAAAAAAAAIQDi2k2bIAAAACAAAAAJAAAAc2hlZXQueGxzbmVzdGVkIGZpbGUgbXVzdCBzdGF5IGluc2lkZSBaSVBQSwMEFAAAAAAAAAAhAPNa8JEaAAAAGgAAAAsAAABaSVBPTkxZLnR4dGRvIG5vdCByZWN1cnNpdmVseSBleHRyYWN0UEsBAhQDFAAAAAAAAAAhAOLaTZsgAAAAIAAAAAkAAAAAAAAAAAAAAIABAAAAAHNoZWV0Lnhsc1BLAQIUAxQAAAAAAAAAIQDzWvCRGgAAABoAAAALAAAAAAAAAAAAAACAAUcAAABaSVBPTkxZLnR4dFBLBQYAAAAAAgACAHAAAACKAAAAAAA=")!
        let xlsxBytes = Data(base64Encoded: "UEsDBBQAAAAAAAAAIQDuR1hmHQAAAB0AAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCI/PjxUeXBlcy8+UEsBAhQDFAAAAAAAAAAhAO5HWGYdAAAAHQAAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwUGAAAAAAEAAQBBAAAATgAAAAAA")!
        let xlsBytes = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) + second
        let pngBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + second
        let genericNames = ["archive.zip", "sheet.xls", "sheet.xlsx", "image.png", "no-extension", "unknown.unrecognized"]
        let genericContents = [zipBytes, xlsBytes, xlsxBytes, pngBytes, second, first]
        let genericFixture = try attached(base: base, header: header, names: genericNames, contents: genericContents)
        let genericArchive = try MDMFExtractor.decodeArchive(genericFixture)
        try require(genericArchive.attachments.map { $0.fileName } == genericNames,
                    "ZIP, Excel, image, extensionless, and unknown filenames are not filtered")
        try require(genericArchive.attachments.map { $0.data } == genericContents,
                    "Generic attachments are preserved without interpreting their content")
        let genericDirectory = directory.appendingPathComponent("generic-attachments")
        try FileManager.default.createDirectory(at: genericDirectory, withIntermediateDirectories: false)
        let genericSource = directory.appendingPathComponent("generic-source.mdmf")
        try genericFixture.write(to: genericSource)
        let genericSaved = try MDMFExtractor.extract(genericSource, outputDirectory: genericDirectory)
        try require(genericSaved.attachmentURLs.map { $0.lastPathComponent } == genericNames,
                    "Generic attachment extensions and extensionless name are preserved when saved")
        try require(try genericSaved.attachmentURLs.map { try Data(contentsOf: $0) } == genericContents,
                    "ZIP remains a ZIP and top-level Excel bytes survive a same-name ZIP member")
        try require(FileManager.default.contentsOfDirectory(atPath: genericDirectory.path).sorted()
                    == (["generic-source.pdf"] + genericNames).sorted(),
                    "Only PDF and six original attachments saved, with no recursive ZIP extraction")

        // Make a later O_EXCL collision exceed the filesystem name limit, forcing rollback.
        let longName = String(repeating: "a", count: 251) + ".bin"
        let preserved = outputDirectory.appendingPathComponent(longName)
        let sentinel = Data("keep existing attachment".utf8)
        try sentinel.write(to: preserved)
        let rollback = try attached(base: base, header: header, names: ["rollback-first.bin", longName], contents: [first, second])
        try rollback.write(to: source)
        let before = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).sorted()
        try rejects("failed later write") { _ = try MDMFExtractor.extract(source, outputDirectory: outputDirectory) }
        try require(FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).sorted() == before,
                    "Failed attachment write removes this operation's PDF and earlier attachments")
        try require(Data(contentsOf: preserved) == sentinel, "Rollback preserves preexisting files")

        let invalid = try attached(base: base, header: header, names: ["valid.bin", "../bad.bin"], contents: [first, second])
        try invalid.write(to: source)
        try rejects("all attachments validate before writing") { _ = try MDMFExtractor.extract(source, outputDirectory: outputDirectory) }
        try require(FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).sorted() == before,
                    "Invalid later attachment creates no earlier output")
    }

    static func be(_ value: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    /// Synthetic containers use arbitrary bytes and filenames; no private attachment content is embedded.
    static func attached(base: Data, header: Data, names: [String], contents: [Data],
                         mutateMetadata: ((inout Data) -> Void)? = nil,
                         mutateStream: ((inout Data) -> Void)? = nil,
                         sentinel: UInt8 = 0, chunkSize: Int = 30_000) throws -> Data {
        var metadata = be(0) + be(names.count) + Data(repeating: 0, count: 268)
        var payload = Data()
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
        for (name, content) in zip(names, contents) {
            let encodedName = name.data(using: String.Encoding(rawValue: encoding))!
            guard encodedName.count < 256 else { throw TestFailure(message: "Synthetic filename too long") }
            metadata.append(encodedName)
            metadata.append(Data(repeating: 0, count: 256 - encodedName.count))
            var stream = be(content.count)
            for offset in stride(from: 0, to: content.count, by: chunkSize) {
                var input = content.subdata(in: offset..<min(content.count, offset + chunkSize))
                input.append(sentinel)
                var count = compressBound(uLong(input.count))
                var buffer = [UInt8](repeating: 0, count: Int(count))
                let status = input.withUnsafeBytes { source in
                    compress2(&buffer, &count, source.bindMemory(to: Bytef.self).baseAddress!, uLong(input.count), Z_DEFAULT_COMPRESSION)
                }
                guard status == Z_OK else { throw TestFailure(message: "Synthetic compression failed") }
                stream.append(be(Int(count)))
                stream.append(contentsOf: buffer.prefix(Int(count)))
            }
            mutateStream?(&stream)
            metadata.append(be(content.count)); metadata.append(be(stream.count)); metadata.append(be(payload.count))
            payload.append(try crypt(stream, operation: CCOperation(kCCEncrypt), key: header.subdata(in: 1045..<1061)))
        }
        mutateMetadata?(&metadata)
        return base + Data("MATTACHDAT".utf8) + be(metadata.count + payload.count) + be(metadata.count)
            + (try crypt(metadata, operation: CCOperation(kCCEncrypt), key: header.subdata(in: 1013..<1029))) + payload
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
