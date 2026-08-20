import CryptoKit
import Foundation

/// Why a CRX3 container was rejected. These are authored strings, never attacker-supplied text, so
/// they are safe to surface in a log line or a diagnostic label.
public enum CRXHeaderProblem: String, Equatable, Sendable {
    case truncated
    case headerLengthOutOfRange
    case zipTokenInHeader
    case malformedProtobuf
    case missingSignedHeaderData
    case invalidCRXIdentifier
    case payloadNotZIP
    case malformedPublicKey
    case unsupportedPublicKey
    case weakPublicKey
}

/// Reads the CRX3 container: a twelve-byte prefix, a protobuf header, then an unmodified ZIP.
///
/// The ZIP inside a CRX3 is byte-identical to the one that was signed, which is the only reason a
/// signature check means anything here — the payload handed to `SafeZIPExtractor` is exactly the
/// payload the proof covers.
///
/// Reference: `chromium/src/components/crx_file/{crx3.proto, crx_verifier.cc, crx_creator.cc}`.
/// Fixtures in `Tests/Fixtures/Packages` are produced by `scripts/make_crx3_fixtures.js`.
enum CRX3Reader {
    /// Shared with CRX2, which is why the version word decides the format, not the magic.
    static let magic: [UInt8] = Array("Cr24".utf8)
    static let supportedVersion: UInt32 = 3

    /// Real headers are around 600 bytes for a single RSA proof. A megabyte is generous and still
    /// bounds how much a hostile file can make us scan.
    static let maximumHeaderBytes = 1 << 20

    /// `"CRX3 SignedData"` plus a NUL: sixteen bytes. The NUL is appended rather than embedded in
    /// the literal so no control character has to appear in this source file.
    private static let signatureContext: [UInt8] = Array("CRX3 SignedData".utf8) + [0x00]

    private static let zipLocalFileHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// End-of-central-directory, Zip64 locator, and Zip64 EOCD. A ZIP reader locates the directory
    /// by scanning backwards for one of these; if the CRX header contains a copy, two readers can
    /// disagree about where the archive begins, and the signature would then cover bytes nobody
    /// extracts. Chromium refuses such a file and so do we.
    private static let zipDirectoryTokens: [[UInt8]] = [
        [0x50, 0x4B, 0x05, 0x06],
        [0x50, 0x4B, 0x06, 0x07],
        [0x50, 0x4B, 0x06, 0x06]
    ]

    struct Container {
        let signature: ExtensionPackageSignature
        /// The embedded ZIP, as a slice of the input. Never copied.
        let payload: Data
    }

    // MARK: - Reading

    /// - Precondition: `data` starts with the CRX magic. `ExtensionPackageReader` checks that.
    static func read(_ data: Data) throws -> Container {
        guard data.count >= 12 else { throw ExtensionInstallError.crxHeaderInvalid(.truncated) }
        let base = data.startIndex

        let version = uint32LE(data, atOffset: 4)
        guard version == supportedVersion else {
            throw ExtensionInstallError.crxVersionUnsupported(version)
        }

        // CRX2 puts the public key length at this offset. Reading it as a header length is the
        // classic silent misparse, so the version check above has to come first.
        let declaredHeaderLength = uint32LE(data, atOffset: 8)
        guard declaredHeaderLength > 0,
              declaredHeaderLength <= UInt32(maximumHeaderBytes),
              Int(declaredHeaderLength) <= data.count - 12 else {
            throw ExtensionInstallError.crxHeaderInvalid(.headerLengthOutOfRange)
        }

        let headerStart = base + 12
        let headerEnd = headerStart + Int(declaredHeaderLength)
        let header = [UInt8](data[headerStart..<headerEnd])
        let payload = data[headerEnd...]

        for token in zipDirectoryTokens where contains(header, token) {
            throw ExtensionInstallError.crxHeaderInvalid(.zipTokenInHeader)
        }
        guard payload.count >= 4,
              payload.prefix(4).elementsEqual(zipLocalFileHeader) else {
            throw ExtensionInstallError.crxHeaderInvalid(.payloadNotZIP)
        }

        return try verify(header: header, payload: payload)
    }

    private static func verify(header: [UInt8], payload: Data) throws -> Container {
        let fields = try protobufFields(in: header[...])

        let signedHeaderFields = fields.filter { $0.number == 10000 }
        guard signedHeaderFields.count == 1 else {
            throw ExtensionInstallError.crxHeaderInvalid(.missingSignedHeaderData)
        }
        let signedHeaderData = Array(signedHeaderFields[0].value)

        // SignedData { optional bytes crx_id = 1 } — exactly sixteen raw bytes.
        let identifierFields = try protobufFields(in: signedHeaderData[...]).filter { $0.number == 1 }
        guard identifierFields.count == 1, identifierFields[0].value.count == 16 else {
            throw ExtensionInstallError.crxHeaderInvalid(.invalidCRXIdentifier)
        }
        let declaredIdentifier = Array(identifierFields[0].value)

        // Field 3 is sha256_with_ecdsa. This build has no ECDSA path, so a package proved only
        // that way is reported as unverifiable rather than quietly treated as trusted.
        let rsaProofs = fields.filter { $0.number == 2 }
        guard !rsaProofs.isEmpty else {
            return Container(signature: .unsigned(.noSupportedProof), payload: payload)
        }

        let message = signedMessage(signedHeaderData: signedHeaderData, archive: payload)
        var identifierMatched = false
        for proof in rsaProofs {
            let parts = try protobufFields(in: proof.value)
            guard let publicKey = parts.first(where: { $0.number == 1 })?.value,
                  let signature = parts.first(where: { $0.number == 2 })?.value else {
                throw ExtensionInstallError.crxHeaderInvalid(.malformedProtobuf)
            }
            let publicKeyData = Data(publicKey)
            // Every proof present must hold. Accepting a file because one of several proofs passed
            // would let an attacker append a proof of their own and have it ignored.
            guard try DERPublicKey.verifyPKCS1SHA256(
                message: message,
                signature: Data(signature),
                spkiDER: publicKeyData
            ) else {
                throw ExtensionInstallError.crxSignatureInvalid
            }
            if Array(SHA256.hash(data: publicKeyData).prefix(16)) == declaredIdentifier {
                identifierMatched = true
            }
        }

        // A genuine signature over somebody else's crx_id proves nothing about who published this.
        guard identifierMatched else { throw ExtensionInstallError.crxIdentifierMismatch }
        return Container(
            signature: .verified(publisherIdentifier: publisherIdentifier(declaredIdentifier)),
            payload: payload
        )
    }

    /// The exact bytes a CRX3 signature covers: context, the length of `signed_header_data`, that
    /// data, then the archive. The length prefix is of the signed header, not of the outer header —
    /// getting that wrong yields a signature that verifies against nothing.
    private static func signedMessage(signedHeaderData: [UInt8], archive: Data) -> Data {
        var message = Data()
        message.reserveCapacity(signatureContext.count + 4 + signedHeaderData.count + archive.count)
        message.append(contentsOf: signatureContext)
        var length = UInt32(signedHeaderData.count).littleEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(contentsOf: signedHeaderData)
        message.append(archive)
        return message
    }

    /// Chromium renders the sixteen id bytes as thirty-two characters drawn from `a`–`p`, one per
    /// nibble. This is the id users see in the Chrome Web Store URL.
    static func publisherIdentifier(_ identifier: [UInt8]) -> String {
        let alphabet = Array("abcdefghijklmnop")
        var result = ""
        result.reserveCapacity(identifier.count * 2)
        for byte in identifier {
            result.append(alphabet[Int(byte >> 4)])
            result.append(alphabet[Int(byte & 0x0F)])
        }
        return result
    }

    // MARK: - Protobuf

    struct ProtobufField {
        let number: Int
        let value: ArraySlice<UInt8>
    }

    /// Collects length-delimited fields and steps over every other wire type.
    ///
    /// Skipping unknown fields instead of rejecting them is what protobuf requires of a reader: a
    /// future CRX3 revision that adds a field must not make today's packages unreadable. Groups
    /// (wire types 3 and 4) are deprecated and have no defined skip, so they are refused.
    ///
    /// Field 10000 carries a three-byte tag. A reader that assumes one-byte tags desynchronises
    /// exactly here, which is why tags are read as full varints.
    static func protobufFields(in bytes: ArraySlice<UInt8>) throws -> [ProtobufField] {
        var fields: [ProtobufField] = []
        var index = bytes.startIndex

        while index < bytes.endIndex {
            let tag = try varint(bytes, at: &index)
            let wireType = tag & 0x07
            let number = Int(truncatingIfNeeded: tag >> 3)
            guard number > 0 else { throw ExtensionInstallError.crxHeaderInvalid(.malformedProtobuf) }

            switch wireType {
            case 0:
                _ = try varint(bytes, at: &index)
            case 1:
                try skip(8, in: bytes, at: &index)
            case 5:
                try skip(4, in: bytes, at: &index)
            case 2:
                let length = try varint(bytes, at: &index)
                guard length <= UInt64(bytes.endIndex - index) else {
                    throw ExtensionInstallError.crxHeaderInvalid(.malformedProtobuf)
                }
                let end = index + Int(length)
                fields.append(ProtobufField(number: number, value: bytes[index..<end]))
                index = end
            default:
                throw ExtensionInstallError.crxHeaderInvalid(.malformedProtobuf)
            }
        }
        return fields
    }

    private static func varint(_ bytes: ArraySlice<UInt8>, at index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            guard shift <= 63 else { throw ExtensionInstallError.crxHeaderInvalid(.malformedProtobuf) }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw ExtensionInstallError.crxHeaderInvalid(.malformedProtobuf)
    }

    private static func skip(_ count: Int, in bytes: ArraySlice<UInt8>, at index: inout Int) throws {
        guard bytes.endIndex - index >= count else {
            throw ExtensionInstallError.crxHeaderInvalid(.malformedProtobuf)
        }
        index += count
    }

    // MARK: - Bytes

    private static func uint32LE(_ data: Data, atOffset offset: Int) -> UInt32 {
        let index = data.startIndex + offset
        return UInt32(data[index])
            | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16
            | UInt32(data[index + 3]) << 24
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let last = haystack.count - needle.count
        var start = 0
        while start <= last {
            var offset = 0
            while offset < needle.count, haystack[start + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return true }
            start += 1
        }
        return false
    }
}
