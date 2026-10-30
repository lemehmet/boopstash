#if os(macOS)
import Foundation
import Security

/// This process's code signature, read from the system.
enum LiveSigning {
    /// The team that signed the running app; nil when it was signed ad hoc
    /// (Debug, CI) or not at all.
    static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
#endif
