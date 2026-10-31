import BoopstashCore
import SwiftUI

// Label chips on the Mac (#183) and iOS (#184), from Core's catalog and
// contrast rule.

extension Color {
    /// A label's `#rrggbb`; grey for anything else.
    init(labelHex hex: String) {
        guard let (red, green, blue) = LabelColor.components(hex) else {
            self = .gray
            return
        }
        self.init(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

/// A label as a coloured capsule, its text black or white, whichever has
/// the higher contrast on the fill (4.5:1 or more for every preset, in
/// light and dark mode alike, since neither colour depends on the mode).
///
/// By default the chip is as wide as its name, which `LabelChips` relies on
/// to fit whole chips and count the rest in "+N". With `truncates`, a name
/// wider than the space offered ends in "…" instead, so a long name cannot
/// push its neighbours out of a row (#193); the full name stays in the
/// tooltip and the accessibility label.
struct LabelChip: View {
    let name: String
    let color: String
    var font: Font = .caption2.weight(.medium)
    var truncates = false

    init(_ label: NoteLabel, font: Font = .caption2.weight(.medium), truncates: Bool = false) {
        self.init(name: label.name, color: label.color, font: font, truncates: truncates)
    }

    init(name: String, color: String, font: Font = .caption2.weight(.medium), truncates: Bool = false) {
        self.name = name
        self.color = color
        self.font = font
        self.truncates = truncates
    }

    var body: some View {
        let chip = Text(name)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(Color(labelHex: LabelColor.textColor(on: color)))
            .background(Capsule().fill(Color(labelHex: color)))
        if truncates {
            chip
                .fixedSize(horizontal: false, vertical: true)
                .help(name)
                .accessibilityLabel(name)
        } else {
            chip.fixedSize()
        }
    }
}

/// A row's chips. Those that do not fit become "+N". With `onSelect`
/// (the Mac), clicking a chip adds its label to the filter; without it
/// (iOS, where labels are read only), the chips are not buttons.
struct LabelChips: View {
    let labels: [NoteLabel]
    var font: Font = .caption2.weight(.medium)
    var onSelect: ((NoteLabel) -> Void)?
    /// Arrangements tried, most chips first; past this many, the rest are
    /// counted in "+N" whatever the width.
    private static let mostShown = 6

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: min(labels.count, Self.mostShown), through: 0, by: -1)), id: \.self) { shown in
                arrangement(showing: shown)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Labels")
    }

    private func arrangement(showing shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(labels.prefix(shown)) { label in
                if let onSelect {
                    Button { onSelect(label) } label: { LabelChip(label, font: font) }
                        .buttonStyle(.plain)
                        .help(label.details.isEmpty ? "Filter by \(label.name)" : "\(label.details) — click to filter by \(label.name)")
                        .accessibilityLabel(label.name)
                        .accessibilityHint("Adds this label to the filter")
                } else {
                    LabelChip(label, font: font)
                        .accessibilityLabel(label.details.isEmpty ? label.name : "\(label.name), \(label.details)")
                }
            }
            if shown < labels.count {
                let hidden = labels.dropFirst(shown)
                Text("+\(hidden.count)")
                    .font(font)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(.secondary)
                    .background(Capsule().strokeBorder(.secondary.opacity(0.6)))
                    .fixedSize()
                    .help(hidden.map(\.name).joined(separator: ", "))
                    .accessibilityLabel(hidden.map(\.name).joined(separator: ", "))
            }
        }
    }
}
