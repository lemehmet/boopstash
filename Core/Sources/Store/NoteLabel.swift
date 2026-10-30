import Foundation
import GRDB

/// A label from the one shared catalog (#182), as on GitHub issues: a name,
/// a colour and a description. Notes carry labels by ID (`noteLabel`), so
/// renaming or recolouring a label changes it on every note (ADR 0011).
/// Called `NoteLabel` so it never shadows SwiftUI's `Label` in the apps.
public struct NoteLabel: Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Trimmed, never empty; unique in the catalog regardless of case.
    public var name: String
    /// `#rrggbb`, lowercase (`LabelColor.parse`).
    public var color: String
    /// The label's description; empty for none.
    public var details: String
    public var createdAt: Date { didSet { createdAt = createdAt.storedPrecision } }
    public var updatedAt: Date { didSet { updatedAt = updatedAt.storedPrecision } }

    public init(id: UUID = UUID(), name: String, color: String, details: String = "", createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.details = details
        self.createdAt = createdAt.storedPrecision
        self.updatedAt = (updatedAt ?? createdAt).storedPrecision
    }

    /// What uniqueness compares: the trimmed name, case folded the same way
    /// on every device, so two devices pick the same duplicate.
    public static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive], locale: nil)
    }

    /// Of two labels with the same name, the one every device keeps: the
    /// later `createdAt`, ties broken by the lower UUID. The later, so a
    /// label deleted and its name made again keeps the new one, whichever of
    /// the deletion and the new label arrives first (ADR 0011).
    public static func survivor(_ a: NoteLabel, _ b: NoteLabel) -> NoteLabel {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt ? a : b }
        return a.id.uuidString.lowercased() <= b.id.uuidString.lowercased() ? a : b
    }
}

extension NoteLabel: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "label"

    public init(row: Row) throws {
        self.init(id: row["id"], name: row["name"], color: row["color"], details: row["details"],
                  createdAt: row["createdAt"], updatedAt: row["updatedAt"])
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["nameKey"] = Self.nameKey(name)
        container["color"] = color
        container["details"] = details
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }
}

/// What can go wrong changing the label catalog.
public enum LabelError: Error, Equatable, Sendable {
    case emptyName
    /// Another label already has this name, in any case.
    case duplicateName(String)
    case invalidColor(String)
    case notFound
}

/// Label colours as `#rrggbb` (#182): parsing, a GitHub-like palette, and
/// the text colour that reads on one.
public enum LabelColor {
    /// The colour as lowercase `#rrggbb`, or nil for anything else: the
    /// short `#abc` form, a missing `#`, other lengths or non-hex digits.
    public static func parse(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 7, trimmed.first == "#",
              trimmed.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { return nil }
        return trimmed.lowercased()
    }

    /// Red, green and blue, 0...255.
    public static func components(_ hex: String) -> (red: Int, green: Int, blue: Int)? {
        guard let parsed = parse(hex), let value = Int(parsed.dropFirst(), radix: 16) else { return nil }
        return ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
    }

    public static func format(red: Int, green: Int, blue: Int) -> String {
        let clamp = { (value: Int) in min(max(value, 0), 255) }
        return String(format: "#%02x%02x%02x", clamp(red), clamp(green), clamp(blue))
    }

    /// The colours GitHub offers for new labels.
    public static let palette = [
        "#b60205", "#d93f0b", "#fbca04", "#0e8a16", "#006b75", "#1d76db", "#0052cc", "#5319e7",
        "#e99695", "#f9d0c4", "#fef2c0", "#c2e0c6", "#bfdadc", "#c5def5", "#bfd4f2", "#d4c5f9",
    ]

    public static func random<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        palette.randomElement(using: &generator) ?? palette[0]
    }

    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    public static func relativeLuminance(_ hex: String) -> Double? {
        guard let (red, green, blue) = components(hex) else { return nil }
        func linear(_ channel: Int) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Whether text on `background` reads best in black (else white): the
    /// one with the higher contrast ratio. Unparseable input gets black.
    public static func prefersDarkText(on background: String) -> Bool {
        guard let luminance = relativeLuminance(background) else { return true }
        let againstBlack = (luminance + 0.05) / 0.05
        let againstWhite = 1.05 / (luminance + 0.05)
        return againstBlack >= againstWhite
    }
}
