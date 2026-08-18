import Foundation

enum BoundedJSONPreflightError: Error, Equatable {
    case nestingLimit
    case stringLimit
    case structuralLimit
    case malformedStructure
}

enum BoundedJSONPreflight {
    static func validate(
        _ data: Data,
        maximumDepth: Int = 32,
        maximumStringBytes: Int = 8_192,
        maximumStructuralTokens: Int = 50_000
    ) throws {
        var depth = 0
        var inString = false
        var escaped = false
        var stringBytes = 0
        var structuralTokens = 0

        for byte in data {
            if inString {
                if byte == 0x22, !escaped {
                    inString = false
                } else {
                    // Count the encoded representation, including backslashes and escaped
                    // bytes. This is deliberately conservative and prevents escape-heavy
                    // strings from bypassing the pre-decode allocation limit.
                    stringBytes += 1
                    guard stringBytes <= maximumStringBytes else {
                        throw BoundedJSONPreflightError.stringLimit
                    }
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    }
                }
                continue
            }

            switch byte {
            case 0x22:
                inString = true
                stringBytes = 0
            case 0x7B, 0x5B: // { [
                depth += 1
                structuralTokens += 1
                guard depth <= maximumDepth else {
                    throw BoundedJSONPreflightError.nestingLimit
                }
            case 0x7D, 0x5D: // } ]
                depth -= 1
                guard depth >= 0 else {
                    throw BoundedJSONPreflightError.malformedStructure
                }
            case 0x2C, 0x3A: // , :
                structuralTokens += 1
            default:
                break
            }
            guard structuralTokens <= maximumStructuralTokens else {
                throw BoundedJSONPreflightError.structuralLimit
            }
        }

        guard depth == 0, !inString, !escaped else {
            throw BoundedJSONPreflightError.malformedStructure
        }
    }
}
