import BoopstashCore
import SwiftUI
import Testing
@testable import Boopstash

/// A long label name in Settings ▸ Labels and the label editor (#193): the
/// chip truncates instead of pushing Edit and Delete… out of the row. No
/// store: the views take a label value.
@MainActor
struct LabelChipLayoutTests {
    /// 200 characters, as in the issue's acceptance.
    let longName = String(repeating: "long label name ", count: 13).prefix(200).description
    let color = "#1f6feb"

    private func size(_ view: some View, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 1000))
    }

    @Test func aTruncatingChipFitsTheWidthItIsOffered() {
        #expect(longName.count == 200)
        let chip = LabelChip(name: longName, color: color, font: .callout.weight(.medium), truncates: true)
        #expect(size(chip, width: 200).width <= 200)
    }

    @Test func theNoteListChipKeepsItsWholeName() {
        // LabelChips' ViewThatFits overflow relies on a chip as wide as its name.
        let chip = LabelChip(name: longName, color: color, font: .callout.weight(.medium))
        #expect(size(chip, width: 200).width > 600)
    }

    @Test func aSettingsRowWithALongNameFitsTheSettingsWidth() {
        let label = NoteLabel(name: longName, color: color, details: "A description", createdAt: Date())
        let row = LabelSettingsRow(label: label, uses: 3, onEdit: {}, onDelete: {})
        // Settings is 520 wide; the grouped form's insets leave less.
        #expect(size(row, width: 440).width <= 440)
    }
}
