import Foundation
import CommonCrypto
import PDFKit
import Darwin
import CoreFoundation
import zlib

struct ExtractionResult {
    let inputURL: URL
    let outputURL: URL
    let pageCount: Int
    let attachmentURLs: [URL]
    var outputURLs: [URL] { [outputURL] + attachmentURLs }
}

struct DecodedAttachment {
    let fileName: String
    let data: Data
}

struct DecodedArchive {
    let pdf: Data
    let pageCount: Int
    let attachments: [DecodedAttachment]
}

enum ExtractionError: LocalizedError {
    case unsupported(String)
    case damaged(String)
    case tooLarge
    case invalidPDF
    case cannotRead(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let detail):
            return "아직 지원하지 않는 MDMF 형식입니다. \(detail)"
        case .damaged(let detail):
            return "파일이 손상되었거나 끝까지 다운로드되지 않았습니다. \(detail)"
        case .tooLarge:
            return "입력 파일 또는 추출 결과 전체 크기가 100 MB를 넘으면 지원하지 않습니다."
        case .invalidPDF:
            return "정상적인 PDF를 확인할 수 없습니다. 이 MDMF 형식은 지원하지 않거나 파일이 손상되었습니다."
        case .cannotRead(let detail):
            return "파일을 읽을 수 없습니다. \(detail)"
        case .cannotWrite(let detail):
            return "파일을 저장할 수 없습니다. \(detail)"
        }
    }
}

/// Offline reader for the verified MDMFILEFXC / version 11 / 2227-byte header layout.
/// Extracts the PDF and the optional attachment container; does not verify the issuer's signature.
enum MDMFExtractor {
    static let maximumInputSize = 100_000_000
    private static let headerLength = 2227
    private static let headerKey = Data("dONGHwaMAnSeMfan".utf8)

    static func extract(_ input: URL, outputDirectory: URL? = nil) throws -> ExtractionResult {
        let raw = try readBounded(input)
        // Decode and validate every attachment before creating any output.
        let archive = try decodeArchive(raw)
        let directory = outputDirectory ?? input.deletingLastPathComponent()
        guard directory.isFileURL else {
            throw ExtractionError.cannotWrite("로컬 폴더를 선택해 주세요.")
        }
        let base = input.deletingPathExtension().lastPathComponent
        var created: [URL] = []
        do {
            let output = try writeExclusive(archive.pdf, directory: directory,
                                            fileName: "\(base.isEmpty ? "추출한 공문" : base).pdf")
            created.append(output)
            for attachment in archive.attachments {
                created.append(try writeExclusive(attachment.data, directory: directory,
                                                   fileName: attachment.fileName))
            }
            return ExtractionResult(inputURL: input, outputURL: output, pageCount: archive.pageCount,
                                    attachmentURLs: Array(created.dropFirst()))
        } catch {
            for url in created.reversed() { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    static func decode(_ data: Data) throws -> Data {
        try decodeArchive(data).pdf
    }

    static func decodeArchive(_ data: Data) throws -> DecodedArchive {
        guard data.count <= maximumInputSize else { throw ExtractionError.tooLarge }
        guard data.count >= 22 else { throw ExtractionError.damaged("파일 머리말이 부족합니다.") }
        guard try bytes(data, at: 0, count: 10) == Data("MDMFILEFXC".utf8) else {
            throw ExtractionError.unsupported("MDMFILEFXC 파일만 지원합니다.")
        }
        let declaredHeaderLength = try decimal(data, at: 10, count: 10)
        guard declaredHeaderLength == headerLength,
              try bytes(data, at: 20, count: 2) == Data("11".utf8) else {
            throw ExtractionError.unsupported("현재 버전 11, 헤더 2227바이트 형식만 지원합니다.")
        }

        let header = try decrypt(try bytes(data, at: 22, count: headerLength), key: headerKey)
        let pdfLength = try decimal(header, at: 0, count: 10)
        let secondaryLength = try decimal(header, at: 10, count: 10)
        let recordLength = try decimal(header, at: 404, count: 10)
        guard secondaryLength == 0, recordLength == 20 else {
            throw ExtractionError.unsupported("문서 내부 구성 또는 추가 데이터 형식이 다릅니다.")
        }
        guard pdfLength > 8 else { throw ExtractionError.invalidPDF }
        guard pdfLength <= maximumInputSize else { throw ExtractionError.tooLarge }
        let contentKey = try bytes(header, at: 1029, count: 16)

        // The metadata is length-prefixed ASCII. No metadata is executed or trusted as a path.
        let metadataPrefix = 22 + headerLength
        let metadataLength = try decimal(data, at: metadataPrefix, count: 10)
        let metadataStart = metadataPrefix + 10
        try checkRange(data, at: metadataStart, count: metadataLength)
        let recordStart = metadataStart + metadataLength
        try checkRange(data, at: recordStart, count: recordLength)
        let pdfStart = recordStart + recordLength
        let encryptedPDF = try bytes(data, at: pdfStart, count: pdfLength)
        let pdf = try decrypt(encryptedPDF, key: contentKey)

        // Validate before any file is created. Preserve the original embedded PDF exactly.
        let pdfSignature = Data("%PDF-".utf8)
        let eof = Data("%%EOF".utf8)
        guard pdf.starts(with: pdfSignature) else { throw ExtractionError.invalidPDF }
        let whitespace: Set<UInt8> = [0, 9, 10, 12, 13, 32]
        var end = pdf.endIndex
        while end > pdf.startIndex, whitespace.contains(pdf[pdf.index(before: end)]) {
            end = pdf.index(before: end)
        }
        guard end >= eof.count, pdf[(end - eof.count)..<end] == eof,
              let document = PDFDocument(data: pdf),
              !document.isEncrypted, !document.isLocked, document.pageCount > 0 else {
            throw ExtractionError.invalidPDF
        }
        for page in 0..<document.pageCount {
            guard document.page(at: page) != nil else { throw ExtractionError.invalidPDF }
        }
        let attachments = try decodeAttachments(data, at: pdfStart + pdfLength, header: header,
                                                pdfLength: pdfLength)
        return DecodedArchive(pdf: pdf, pageCount: document.pageCount, attachments: attachments)
    }

    private static func decodeAttachments(_ raw: Data, at start: Int, header: Data,
                                          pdfLength: Int) throws -> [DecodedAttachment] {
        if start == raw.count { return [] }
        let marker = Data("MATTACHDAT".utf8)
        guard try bytes(raw, at: start, count: marker.count) == marker else {
            throw ExtractionError.unsupported("PDF 뒤의 추가 데이터 형식을 확인할 수 없습니다.")
        }
        let totalLength = try bigEndian(raw, at: start + 10)
        let metadataLength = try bigEndian(raw, at: start + 14)
        guard totalLength == raw.count - start - 18,
              metadataLength >= 276, metadataLength <= 1_048_576,
              metadataLength <= totalLength else {
            throw ExtractionError.damaged("첨부 목록의 크기가 올바르지 않습니다.")
        }
        let metadata = try decrypt(try bytes(raw, at: start + 18, count: metadataLength),
                                   key: try bytes(header, at: 1013, count: 16))
        let textLength = try bigEndian(metadata, at: 0)
        try checkRange(metadata, at: 4, count: textLength)
        let count = try bigEndian(metadata, at: 4 + textLength)
        guard count <= 1_000 else { throw ExtractionError.damaged("첨부 파일 수가 너무 많습니다.") }
        let recordsStart = 4 + textLength + 4 + 268 // Count, main PDF record, attachment records.
        guard recordsStart <= metadata.count,
              count * 268 == metadata.count - recordsStart else {
            throw ExtractionError.damaged("첨부 목록의 구성이 올바르지 않습니다.")
        }
        let payloadStart = start + 18 + metadataLength
        let payloadLength = totalLength - metadataLength
        let attachmentKey = try bytes(header, at: 1045, count: 16)
        var attachments: [DecodedAttachment] = []
        var expectedOffset = 0
        var outputSize = pdfLength
        for index in 0..<count {
            let record = recordsStart + index * 268
            let fileName = try attachmentName(try bytes(metadata, at: record, count: 256))
            let originalSize = try bigEndian(metadata, at: record + 256)
            let storedSize = try bigEndian(metadata, at: record + 260)
            let offset = try bigEndian(metadata, at: record + 264)
            guard originalSize <= maximumInputSize - outputSize else { throw ExtractionError.tooLarge }
            outputSize += originalSize
            guard offset == expectedOffset, storedSize >= 4,
                  offset <= payloadLength, storedSize <= payloadLength - offset else {
                throw ExtractionError.damaged("첨부 파일의 위치 또는 크기가 올바르지 않습니다.")
            }
            let encrypted = try bytes(raw, at: payloadStart + offset, count: storedSize)
            let compressed = try decrypt(encrypted, key: attachmentKey)
            let content = try inflateAttachment(compressed, expectedSize: originalSize)
            attachments.append(DecodedAttachment(fileName: fileName, data: content))
            expectedOffset += storedSize
        }
        guard expectedOffset == payloadLength else {
            throw ExtractionError.damaged("첨부 데이터에 확인되지 않은 내용이 남아 있습니다.")
        }
        return attachments
    }

    private static func attachmentName(_ field: Data) throws -> String {
        guard let terminator = field.firstIndex(of: 0), terminator > field.startIndex else {
            throw ExtractionError.damaged("첨부 파일 이름이 올바르지 않습니다.")
        }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
        guard let name = String(data: field.prefix(upTo: terminator), encoding: String.Encoding(rawValue: encoding)),
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.utf8.count <= 255 else {
            throw ExtractionError.damaged("안전하게 저장할 수 없는 첨부 파일 이름입니다.")
        }
        return name
    }

    private static func inflateAttachment(_ stream: Data, expectedSize: Int) throws -> Data {
        guard try bigEndian(stream, at: 0) == expectedSize else {
            throw ExtractionError.damaged("첨부 파일의 원본 크기가 일치하지 않습니다.")
        }
        var position = 4
        var output = Data()
        output.reserveCapacity(expectedSize)
        while position < stream.count {
            let compressedSize = try bigEndian(stream, at: position)
            position += 4
            guard compressedSize > 0, compressedSize <= 45_000 else {
                throw ExtractionError.damaged("첨부 압축 블록의 크기가 올바르지 않습니다.")
            }
            let compressed = try bytes(stream, at: position, count: compressedSize)
            position += compressedSize
            var block = [UInt8](repeating: 0, count: 30_001)
            var inflatedSize = uLongf(block.count)
            var consumedSize = uLong(compressed.count)
            let status = compressed.withUnsafeBytes { buffer in
                uncompress2(&block, &inflatedSize,
                            buffer.bindMemory(to: Bytef.self).baseAddress!, &consumedSize)
            }
            guard status == Z_OK, consumedSize == compressed.count,
                  inflatedSize > 0, inflatedSize <= block.count,
                  block[Int(inflatedSize) - 1] == 0 else {
                throw ExtractionError.damaged("첨부 파일의 압축 데이터를 복원할 수 없습니다.")
            }
            let amount = Int(inflatedSize) - 1 // The writer adds one sentinel NUL per zlib block.
            guard amount > 0, amount <= expectedSize - output.count else {
                throw ExtractionError.damaged("첨부 파일의 복원 크기가 올바르지 않습니다.")
            }
            output.append(contentsOf: block.prefix(amount))
        }
        guard output.count == expectedSize else {
            throw ExtractionError.damaged("첨부 파일이 끝까지 복원되지 않았습니다.")
        }
        return output
    }

    private static func bigEndian(_ data: Data, at offset: Int) throws -> Int {
        try bytes(data, at: offset, count: 4).reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func checkRange(_ data: Data, at offset: Int, count: Int) throws {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw ExtractionError.damaged("기록된 데이터 길이가 실제 파일 크기와 맞지 않습니다.")
        }
    }

    private static func bytes(_ data: Data, at offset: Int, count: Int) throws -> Data {
        try checkRange(data, at: offset, count: count)
        let start = data.index(data.startIndex, offsetBy: offset)
        return data.subdata(in: start..<data.index(start, offsetBy: count))
    }

    private static func decimal(_ data: Data, at offset: Int, count: Int) throws -> Int {
        let field = try bytes(data, at: offset, count: count)
        var value = 0
        for digit in field {
            guard digit >= 48, digit <= 57 else {
                throw ExtractionError.damaged("길이 정보가 올바른 숫자가 아닙니다.")
            }
            let (multiplied, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (added, overflow2) = multiplied.addingReportingOverflow(Int(digit - 48))
            guard !overflow1, !overflow2 else {
                throw ExtractionError.damaged("길이 정보가 너무 큽니다.")
            }
            value = added
        }
        return value
    }

    /// The Windows reader resets CBC's zero IV for each 256-byte chunk.
    /// The final incomplete AES block is stored unchanged, without PKCS#7 padding.
    private static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw ExtractionError.invalidPDF }
        var output = encrypted
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { destination in
            encrypted.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        for offset in stride(from: 0, to: encrypted.count, by: 256) {
                            let amount = min(256, encrypted.count - offset) / 16 * 16
                            if amount == 0 { continue }
                            var written = 0
                            let result = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                                 CCOptions(0), keyBytes.baseAddress, key.count,
                                                 ivBytes.baseAddress, source.baseAddress!.advanced(by: offset),
                                                 amount, destination.baseAddress!.advanced(by: offset),
                                                 amount, &written)
                            guard result == kCCSuccess, written == amount else { return result == kCCSuccess ? CCCryptorStatus(kCCDecodeError) : result }
                        }
                        return CCCryptorStatus(kCCSuccess)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ExtractionError.invalidPDF }
        return output
    }

    private static func readBounded(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ExtractionError.cannotRead("로컬 파일을 선택해 주세요.") }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ExtractionError.cannotRead("일반 파일을 선택해 주세요.") }
            guard (values.fileSize ?? 0) <= maximumInputSize else { throw ExtractionError.tooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var result = Data()
            // Bound the read as well as the initial size check in case the file changes.
            while true {
                let amount = min(1_048_576, maximumInputSize - result.count + 1)
                guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else { break }
                result.append(chunk)
                guard result.count <= maximumInputSize else { throw ExtractionError.tooLarge }
            }
            return result
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError.cannotRead(error.localizedDescription)
        }
    }

    private static func writeExclusive(_ data: Data, directory: URL, fileName: String) throws -> URL {
        let name = fileName as NSString
        let fileExtension = name.pathExtension
        let baseName = fileExtension.isEmpty ? fileName : name.deletingPathExtension
        for index in 0..<10_000 {
            let suffix = index == 0 ? "" : " (\(index + 1))"
            let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
            let target = directory.appendingPathComponent("\(baseName)\(suffix)\(extensionSuffix)")
            let descriptor = target.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) } ?? -1
            }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw ExtractionError.cannotWrite(String(cString: strerror(errno)))
            }
            // O_EXCL reserves the name without overwriting existing files or following symlinks.
            var failure: Int32 = 0
            data.withUnsafeBytes { buffer in
                var position = 0
                while position < buffer.count {
                    let amount = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: position), buffer.count - position)
                    if amount < 0, errno == EINTR { continue }
                    if amount <= 0 { failure = amount == 0 ? EIO : errno; break }
                    position += amount
                }
            }
            if Darwin.close(descriptor) != 0, failure == 0 { failure = errno }
            if failure != 0 {
                try? FileManager.default.removeItem(at: target)
                throw ExtractionError.cannotWrite(String(cString: strerror(failure)))
            }
            return target
        }
        throw ExtractionError.cannotWrite("같은 이름의 파일이 너무 많습니다. 다른 저장 폴더를 선택해 주세요.")
    }
}
