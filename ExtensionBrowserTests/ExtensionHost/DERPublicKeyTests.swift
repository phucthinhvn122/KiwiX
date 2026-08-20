import XCTest
@testable import ExtensionBrowser

/// The DER reader in front of `SecKeyCreateWithData`. Everything here is about refusing keys, since
/// the accepting path is already proven end to end by `CRX3PackageTests` verifying a real fixture.
final class DERPublicKeyTests: XCTestCase {
    /// `1.2.840.113549.1.1.1` rsaEncryption.
    private let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    /// `1.2.840.10045.2.1` ecPublicKey — the key type this build cannot verify and must not accept.
    private let ecOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]

    // MARK: - The fixture key

    func testFixtureKeyUnwrapsToAPKCS1Body() throws {
        let spki = try fixturePublicKey()
        let pkcs1 = try DERPublicKey.pkcs1RSAPublicKey(fromSPKI: spki)

        XCTAssertEqual(pkcs1.first, 0x30)
        XCTAssertLessThan(pkcs1.count, spki.count)
    }

    func testSignatureThatDoesNotMatchReturnsFalseInsteadOfThrowing() throws {
        // A key that works and a signature that does not match are two different outcomes. Throwing
        // here would let a broken package be reported as a broken key.
        let spki = try fixturePublicKey()
        let verified = try DERPublicKey.verifyPKCS1SHA256(
            message: Data("some other message".utf8),
            signature: Data(repeating: 0x00, count: 256),
            spkiDER: spki
        )
        XCTAssertFalse(verified)
    }

    func testTrailingBytesAfterTheKeyAreRejected() throws {
        var spki = try fixturePublicKey()
        spki.append(0x00)

        XCTAssertThrowsError(try DERPublicKey.pkcs1RSAPublicKey(fromSPKI: spki)) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .crxHeaderInvalid(.malformedPublicKey))
        }
    }

    // MARK: - Rejections

    func testNonRSAAlgorithmIsRejected() {
        // Handing an EC key to an RSA verifier is the failure this OID check exists to prevent.
        let spki = der(0x30, der(0x30, der(0x06, ecOID)) + der(0x03, [0x00] + rsaPublicKeyBody(modulusBytes: 256)))

        XCTAssertThrowsError(try DERPublicKey.pkcs1RSAPublicKey(fromSPKI: Data(spki))) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .crxHeaderInvalid(.unsupportedPublicKey))
        }
    }

    func testUndersizedModulusIsRejected() {
        let spki = rsaSPKI(body: rsaPublicKeyBody(modulusBytes: 128))

        XCTAssertThrowsError(try DERPublicKey.pkcs1RSAPublicKey(fromSPKI: Data(spki))) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .crxHeaderInvalid(.weakPublicKey))
        }
    }

    func testEvenExponentIsRejected() {
        let spki = rsaSPKI(body: rsaPublicKeyBody(modulusBytes: 256, exponent: [0x01, 0x00, 0x00]))

        XCTAssertThrowsError(try DERPublicKey.pkcs1RSAPublicKey(fromSPKI: Data(spki))) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .crxHeaderInvalid(.malformedPublicKey))
        }
    }

    func testMalformedEncodingsAreRejected() {
        let cases: [(name: String, bytes: [UInt8])] = [
            ("empty", []),
            ("truncated sequence", [0x30, 0x82, 0x01]),
            ("integer where a sequence belongs", [0x02, 0x01, 0x01]),
            // Long form for a length that fits the short form: two encoders would disagree about
            // the same bytes, which is exactly what strict DER exists to prevent.
            ("non-minimal length", [0x30, 0x81, 0x05, 0x02, 0x01, 0x01, 0x05, 0x00]),
            // BER indefinite length. Valid BER, never valid DER.
            ("indefinite length", [0x30, 0x80, 0x02, 0x01, 0x01, 0x00, 0x00]),
            ("length beyond the buffer", [0x30, 0x7F, 0x02, 0x01, 0x01])
        ]

        for testCase in cases {
            XCTAssertThrowsError(
                try DERPublicKey.pkcs1RSAPublicKey(fromSPKI: Data(testCase.bytes)),
                testCase.name
            ) { error in
                XCTAssertEqual(
                    error as? ExtensionInstallError,
                    .crxHeaderInvalid(.malformedPublicKey),
                    testCase.name
                )
            }
        }
    }

    // MARK: - Builders

    private func fixturePublicKey() throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let resourceURL = bundle.resourceURL else {
            throw XCTSkip("Test bundle has no resource URL.")
        }
        let url = resourceURL
            .appendingPathComponent("Fixtures/Packages", isDirectory: true)
            .appendingPathComponent("valid.crx", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Fixture valid.crx is missing from the test bundle at \(url.path).")
            throw XCTSkip("Fixture not bundled.")
        }

        // Pull the key straight out of the fixture rather than committing a second copy of it:
        // one source of truth means the two can never drift apart.
        let data = [UInt8](try Data(contentsOf: url))
        let headerLength = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
        let header = Array(data[12..<(12 + headerLength)])
        let proof = try XCTUnwrap(CRX3Reader.protobufFields(in: header[...]).first { $0.number == 2 })
        let key = try XCTUnwrap(CRX3Reader.protobufFields(in: proof.value).first { $0.number == 1 })
        return Data(key.value)
    }

    private func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [tag]
        if content.count <= 0x7F {
            bytes.append(UInt8(content.count))
        } else if content.count <= 0xFF {
            bytes += [0x81, UInt8(content.count)]
        } else {
            bytes += [0x82, UInt8((content.count >> 8) & 0xFF), UInt8(content.count & 0xFF)]
        }
        return bytes + content
    }

    /// `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    private func rsaPublicKeyBody(modulusBytes: Int, exponent: [UInt8] = [0x01, 0x00, 0x01]) -> [UInt8] {
        // Leading 0x00 is the DER sign byte; the reader must not count it toward the modulus size.
        let modulus = der(0x02, [0x00] + [UInt8](repeating: 0xFF, count: modulusBytes))
        return der(0x30, modulus + der(0x02, exponent))
    }

    private func rsaSPKI(body: [UInt8]) -> [UInt8] {
        der(0x30, der(0x30, der(0x06, rsaOID) + der(0x05, [])) + der(0x03, [0x00] + body))
    }
}
