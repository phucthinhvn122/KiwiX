import Foundation

/// What we could establish about who produced a package.
///
/// The two cases are deliberately not "pass" and "fail". A signature that is present and broken is
/// never represented here at all — that is a hard rejection from `CRX3Reader`. This type only ever
/// says "checked, and it holds" or "there was nothing to check", because §7 treats those very
/// differently: the first installs normally, the second installs only behind a warning and a second
/// confirmation, and a broken one does not install at all.
public enum ExtensionPackageSignature: Equatable, Sendable {
    /// An RSA proof verified against this exact payload, and the declared `crx_id` matched the key
    /// that signed it. The identifier is Chromium's `a`–`p` extension id.
    case verified(publisherIdentifier: String)
    case unsigned(UnsignedReason)

    public enum UnsignedReason: String, Equatable, Sendable {
        /// A plain ZIP. No container, no proof, nothing to verify.
        case plainArchive
        /// A CRX3 whose only proofs use an algorithm this build cannot check (ECDSA).
        case noSupportedProof
    }

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    /// True when installing needs the §7 warning and the second confirmation step.
    public var requiresExplicitTrust: Bool { !isVerified }
}

public struct ExtensionPackage: Sendable {
    public enum Format: String, Equatable, Sendable {
        case zip
        case crx3
    }

    public let format: Format
    public let signature: ExtensionPackageSignature
    /// A plain ZIP, whatever the container was. For CRX3 this is a slice of the original bytes,
    /// unmodified — the same bytes the proof covers.
    public let payload: Data
}

/// Decides what a downloaded or imported file actually is, and how much it can be trusted, before
/// anything is written to disk.
public enum ExtensionPackageReader {
    private static let zipLocalFileHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    public static func read(_ data: Data) throws -> ExtensionPackage {
        if starts(data, with: CRX3Reader.magic) {
            let container = try CRX3Reader.read(data)
            return ExtensionPackage(format: .crx3, signature: container.signature, payload: container.payload)
        }
        if starts(data, with: zipLocalFileHeader) {
            return ExtensionPackage(format: .zip, signature: .unsigned(.plainArchive), payload: data)
        }
        throw ExtensionInstallError.packageFormatUnsupported
    }

    private static func starts(_ data: Data, with prefix: [UInt8]) -> Bool {
        guard data.count >= prefix.count else { return false }
        return data.prefix(prefix.count).elementsEqual(prefix)
    }
}
