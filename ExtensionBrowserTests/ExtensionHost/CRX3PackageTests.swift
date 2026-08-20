import XCTest
@testable import ExtensionBrowser

/// Fixtures come from `scripts/make_crx3_fixtures.js`. Regenerate with `node
/// scripts/make_crx3_fixtures.js`; output is byte-deterministic, so a diff under
/// `Tests/Fixtures/Packages` means the generator changed, never that the run varied.
final class CRX3PackageTests: XCTestCase {
    /// SHA-256(SPKI)[0..16] of the fixture signing key, rendered in Chromium's a-p alphabet.
    private static let fixturePublisher = "kliiopiebkklfgdplbapnchppieailka"

    // MARK: - Fixtures

    private func packageData(named name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let resourceURL = bundle.resourceURL else {
            throw XCTSkip("Test bundle has no resource URL.")
        }
        let url = resourceURL
            .appendingPathComponent("Fixtures/Packages", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Fixture \(name) is missing from the test bundle at \(url.path). Check the Tests/Fixtures folder reference in project.yml.")
            throw XCTSkip("Fixture \(name) not bundled.")
        }
        return try Data(contentsOf: url)
    }

    // MARK: - The happy path

    func testValidPackageVerifiesAndReportsItsPublisher() throws {
        let package = try ExtensionPackageReader.read(packageData(named: "valid.crx"))

        XCTAssertEqual(package.format, .crx3)
        XCTAssertEqual(package.signature, .verified(publisherIdentifier: Self.fixturePublisher))
        XCTAssertTrue(package.signature.isVerified)
        XCTAssertFalse(package.signature.requiresExplicitTrust)

        // The payload handed on for extraction must be the untouched embedded ZIP, because that is
        // the only thing the proof actually covers.
        XCTAssertTrue(package.payload.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]))
        XCTAssertEqual(package.payload, try packageData(named: "unsigned.zip"))
    }

    // MARK: - Rejections

    func testBrokenAndUnsupportedPackagesAreRejectedForTheRightReason() throws {
        // Each fixture isolates one failure. Asserting the specific error matters: "tampered" and
        // "mismatched id" both mean "do not install", but confusing them would hide a real bug —
        // mismatched-id carries a genuine signature and is caught only by the id comparison.
        let expectations: [(name: String, error: ExtensionInstallError)] = [
            ("tampered-payload.crx", .crxSignatureInvalid),
            ("wrong-signature.crx", .crxSignatureInvalid),
            ("mismatched-id.crx", .crxIdentifierMismatch),
            ("crx2.crx", .crxVersionUnsupported(2)),
            ("truncated-header.crx", .crxHeaderInvalid(.headerLengthOutOfRange)),
            ("zero-header.crx", .crxHeaderInvalid(.headerLengthOutOfRange))
        ]

        for expectation in expectations {
            let data = try packageData(named: expectation.name)
            XCTAssertThrowsError(try ExtensionPackageReader.read(data), expectation.name) { error in
                XCTAssertEqual(error as? ExtensionInstallError, expectation.error, expectation.name)
            }
        }
    }

    func testPlainZIPIsUnsignedRatherThanRejected() throws {
        let package = try ExtensionPackageReader.read(packageData(named: "unsigned.zip"))

        XCTAssertEqual(package.format, .zip)
        XCTAssertEqual(package.signature, .unsigned(.plainArchive))
        // Spec §7: nothing to verify means warn and confirm twice, not refuse.
        XCTAssertTrue(package.signature.requiresExplicitTrust)
    }

    func testFileThatIsNeitherZIPNorCRXIsRejected() {
        XCTAssertThrowsError(try ExtensionPackageReader.read(Data("not an archive".utf8))) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .packageFormatUnsupported)
        }
    }

    func testEndOfCentralDirectoryTokenInsideHeaderIsRejected() throws {
        var data = [UInt8](try packageData(named: "valid.crx"))
        // Well inside the 581-byte header. A ZIP reader scanning backwards for the central
        // directory could latch onto this and disagree with us about where the archive starts.
        data.replaceSubrange((12 + 100)..<(12 + 104), with: [0x50, 0x4B, 0x05, 0x06])

        XCTAssertThrowsError(try ExtensionPackageReader.read(Data(data))) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .crxHeaderInvalid(.zipTokenInHeader))
        }
    }

    /// A CRX3 with no RSA proof is the ECDSA-only case: unverifiable by this build, but not forged.
    /// It has to land in `unsigned`, never in `verified` and never as a hard rejection.
    func testCRX3WithoutAnRSAProofIsUnsignedNotTrusted() throws {
        let archive = try packageData(named: "unsigned.zip")
        let identifier = [UInt8](repeating: 0xAB, count: 16)
        let signedHeaderData = lengthDelimited(field: 1, payload: identifier)
        let header = lengthDelimited(field: 10000, payload: signedHeaderData)

        let package = try ExtensionPackageReader.read(crx3(header: header, archive: archive))

        XCTAssertEqual(package.format, .crx3)
        XCTAssertEqual(package.signature, .unsigned(.noSupportedProof))
        XCTAssertTrue(package.signature.requiresExplicitTrust)
    }

    func testCRX3WithoutSignedHeaderDataIsRejected() throws {
        let archive = try packageData(named: "unsigned.zip")
        let header = lengthDelimited(field: 4, payload: [0x01, 0x02, 0x03])

        XCTAssertThrowsError(try ExtensionPackageReader.read(crx3(header: header, archive: archive))) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .crxHeaderInvalid(.missingSignedHeaderData))
        }
    }

    func testCRXIdentifierMustBeExactlySixteenBytes() throws {
        let archive = try packageData(named: "unsigned.zip")
        let signedHeaderData = lengthDelimited(field: 1, payload: [UInt8](repeating: 0xAB, count: 15))
        let header = lengthDelimited(field: 10000, payload: signedHeaderData)

        XCTAssertThrowsError(try ExtensionPackageReader.read(crx3(header: header, archive: archive))) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .crxHeaderInvalid(.invalidCRXIdentifier))
        }
    }

    // MARK: - Protobuf

    func testUnknownFieldsAreSkippedAndGroupsRejected() throws {
        // Wire types 0, 1 and 5 belong to fields a future CRX3 revision might add. Skipping them is
        // what keeps today's reader able to open tomorrow's package.
        var bytes: [UInt8] = []
        bytes += varint(UInt64(7 << 3 | 0)) + varint(300)
        bytes += varint(UInt64(8 << 3 | 5)) + [0x01, 0x02, 0x03, 0x04]
        bytes += varint(UInt64(9 << 3 | 1)) + [UInt8](repeating: 0x00, count: 8)
        bytes += lengthDelimited(field: 2, payload: [0xAA, 0xBB])

        let fields = try CRX3Reader.protobufFields(in: bytes[...])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.number, 2)
        XCTAssertEqual(fields.first.map { Array($0.value) }, [0xAA, 0xBB])

        // Groups (3 and 4) are deprecated and have no defined skip, so a reader cannot resynchronise.
        let group = varint(UInt64(3 << 3 | 3))
        XCTAssertThrowsError(try CRX3Reader.protobufFields(in: group[...])) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .crxHeaderInvalid(.malformedProtobuf))
        }
    }

    func testFieldTenThousandUsesAThreeByteTag() {
        // The one detail a single-byte-tag parser gets wrong, silently.
        XCTAssertEqual(varint(UInt64(10000 << 3 | 2)), [0x82, 0xF1, 0x04])
    }

    func testPublisherIdentifierUsesChromiumAlphabet() {
        // One character per nibble: 0x00 -> "aa", 0x0F -> "ap", 0xF0 -> "pa", 0xFF -> "pp".
        let identifier = CRX3Reader.publisherIdentifier([0x00, 0x0F, 0xF0, 0xFF] + [UInt8](repeating: 0, count: 12))
        XCTAssertTrue(identifier.hasPrefix("aaappapp"))
        XCTAssertEqual(identifier.count, 32)
        XCTAssertTrue(identifier.allSatisfy { ("a"..."p").contains($0) })
    }

    // MARK: - Builders

    private func crx3(header: [UInt8], archive: Data, version: UInt32 = 3) -> Data {
        var data = Data(CRX3Reader.magic)
        data.append(contentsOf: littleEndian(version))
        data.append(contentsOf: littleEndian(UInt32(header.count)))
        data.append(contentsOf: header)
        data.append(archive)
        return data
    }

    private func littleEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    private func lengthDelimited(field: Int, payload: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(payload.count)) + payload
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }
}
