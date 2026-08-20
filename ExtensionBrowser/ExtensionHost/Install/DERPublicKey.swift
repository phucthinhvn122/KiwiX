import Foundation
import Security

/// Reads the one DER shape CRX3 needs: an X.509 `SubjectPublicKeyInfo` wrapping an RSA key.
///
/// `SecKeyCreateWithData` wants a PKCS#1 `RSAPublicKey`; CRX3 stores SPKI. Unwrapping is therefore
/// unavoidable, and unwrapping blindly would hand an ECDSA key to an RSA verifier — which is why
/// the algorithm OID is checked here rather than assumed from context.
///
/// Only a strict subset of DER is accepted: definite lengths, minimal long form, and no trailing
/// bytes at any level. A permissive reader would let two parsers disagree about the same key, and
/// the whole point of this file is that the bytes we hash are the bytes we verify.
enum DERPublicKey {
    /// `1.2.840.113549.1.1.1` (rsaEncryption), as OID content bytes.
    private static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    /// 2048-bit. Below this the signature check would be theatre rather than a control.
    static let minimumModulusBytes = 256
    /// 8192-bit. An upper bound so a hostile key cannot turn verification into a stall.
    static let maximumModulusBytes = 1_024

    // MARK: - Verification

    /// Verifies an RSA PKCS#1 v1.5 SHA-256 signature made by the key in `spkiDER`.
    ///
    /// - Returns: `false` when the signature simply does not match the message.
    /// - Throws: `ExtensionInstallError.crxHeaderInvalid` when the key itself cannot be used, which
    ///   is a different failure from a signature that does not match and must not be conflated.
    static func verifyPKCS1SHA256(message: Data, signature: Data, spkiDER: Data) throws -> Bool {
        let pkcs1 = try pkcs1RSAPublicKey(fromSPKI: spkiDER)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else {
            throw ExtensionInstallError.crxHeaderInvalid(.unsupportedPublicKey)
        }
        return SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            signature as CFData,
            nil
        )
    }

    // MARK: - SPKI

    /// Unwraps `SubjectPublicKeyInfo` to the PKCS#1 body `SecKeyCreateWithData` expects.
    static func pkcs1RSAPublicKey(fromSPKI spki: Data) throws -> Data {
        let bytes = [UInt8](spki)

        let outer = try element(in: bytes, at: 0, limit: bytes.count)
        guard outer.tag == .sequence, outer.end == bytes.count else { throw malformed }

        let algorithm = try element(in: bytes, at: outer.content.lowerBound, limit: outer.content.upperBound)
        guard algorithm.tag == .sequence else { throw malformed }

        let oid = try element(in: bytes, at: algorithm.content.lowerBound, limit: algorithm.content.upperBound)
        guard oid.tag == .objectIdentifier, Array(bytes[oid.content]) == rsaEncryptionOID else {
            throw ExtensionInstallError.crxHeaderInvalid(.unsupportedPublicKey)
        }
        // RFC 4055: for rsaEncryption the parameters field is present and NULL. Some encoders omit
        // it. Anything else means a different algorithm reusing the same OID position.
        if oid.end < algorithm.content.upperBound {
            let parameters = try element(in: bytes, at: oid.end, limit: algorithm.content.upperBound)
            guard parameters.tag == .null,
                  parameters.content.isEmpty,
                  parameters.end == algorithm.content.upperBound else { throw malformed }
        }

        let bitString = try element(in: bytes, at: algorithm.end, limit: outer.content.upperBound)
        guard bitString.tag == .bitString,
              bitString.end == outer.content.upperBound,
              !bitString.content.isEmpty,
              bytes[bitString.content.lowerBound] == 0x00 else { throw malformed }

        let keyRange = (bitString.content.lowerBound + 1)..<bitString.content.upperBound
        try validateRSAPublicKey(bytes, in: keyRange)
        return Data(bytes[keyRange])
    }

    /// Checks the PKCS#1 body parses and the modulus is a size worth trusting.
    private static func validateRSAPublicKey(_ bytes: [UInt8], in range: Range<Int>) throws {
        let sequence = try element(in: bytes, at: range.lowerBound, limit: range.upperBound)
        guard sequence.tag == .sequence, sequence.end == range.upperBound else { throw malformed }

        let modulus = try element(in: bytes, at: sequence.content.lowerBound, limit: sequence.content.upperBound)
        guard modulus.tag == .integer, !modulus.content.isEmpty else { throw malformed }
        // A leading zero is the DER sign byte, not part of the magnitude.
        var magnitude = modulus.content
        if bytes[magnitude.lowerBound] == 0x00 {
            magnitude = (magnitude.lowerBound + 1)..<magnitude.upperBound
        }
        guard magnitude.count >= minimumModulusBytes, magnitude.count <= maximumModulusBytes else {
            throw ExtensionInstallError.crxHeaderInvalid(.weakPublicKey)
        }

        let exponent = try element(in: bytes, at: modulus.end, limit: sequence.content.upperBound)
        guard exponent.tag == .integer,
              exponent.end == sequence.content.upperBound,
              let lastByte = exponent.content.last.map({ bytes[$0] }),
              lastByte & 1 == 1 else { throw malformed }
    }

    // MARK: - DER primitives

    private enum Tag: UInt8 {
        case integer = 0x02
        case bitString = 0x03
        case null = 0x05
        case objectIdentifier = 0x06
        case sequence = 0x30
    }

    private struct Element {
        let tag: Tag?
        /// Content bytes, excluding tag and length.
        let content: Range<Int>
        /// One past the last byte of the whole element.
        let end: Int
    }

    private static var malformed: ExtensionInstallError {
        .crxHeaderInvalid(.malformedPublicKey)
    }

    private static func element(in bytes: [UInt8], at start: Int, limit: Int) throws -> Element {
        guard start >= 0, start < limit, limit <= bytes.count else { throw malformed }
        var cursor = start + 1
        guard cursor < limit else { throw malformed }

        let lengthByte = bytes[cursor]
        cursor += 1
        var length = 0
        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
        } else {
            // 0x80 is BER indefinite length and 0xFF is reserved; neither is valid DER.
            let byteCount = Int(lengthByte & 0x7F)
            guard byteCount > 0, byteCount <= 4, cursor + byteCount <= limit else { throw malformed }
            guard bytes[cursor] != 0x00 else { throw malformed }
            for _ in 0..<byteCount {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
            // Long form for a value that fits the short form is a non-minimal encoding.
            guard length > 0x7F else { throw malformed }
        }

        guard length <= limit - cursor else { throw malformed }
        return Element(tag: Tag(rawValue: bytes[start]), content: cursor..<(cursor + length), end: cursor + length)
    }
}
