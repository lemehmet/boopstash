import Foundation

/// Whether a pasteboard's contents may be stored, decided from its type
/// identifiers alone (ADR 0001). Password managers and clipboard tools mark
/// what they put on the pasteboard following the conventions at
/// nspasteboard.org; a stash that keeps everything must honour them even when
/// the user captures on purpose, because the user rarely knows the marker is
/// there.
public enum CapturePolicy {
    public enum Decision: Equatable, Sendable {
        case accept
        /// A password manager marked the item as secret.
        case refuseConcealed
        /// The writer marked the item as not meant to be kept.
        case refuseTransient
    }

    static let concealed: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "com.agilebits.onepassword", // 1Password 7 and earlier, before the shared marker
    ]

    static let transient: Set<String> = [
        "org.nspasteboard.TransientType",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
    ]

    /// Concealed wins over transient: it is the stronger statement and the
    /// one the user is told about.
    public static func decide(types: [String]) -> Decision {
        let types = Set(types)
        if !types.isDisjoint(with: concealed) { return .refuseConcealed }
        if !types.isDisjoint(with: transient) { return .refuseTransient }
        return .accept
    }
}
