import BoopstashCore
import SwiftUI

/// What's New (#253): releases newest first, with Copy and Save as Note
/// for exactly what is listed. Used by the sheet shown once after an update
/// and by the full list in Help and Settings, on the Mac and iOS.
struct ReleaseNotesView: View {
    let releases: [ReleaseNotes.Release]
    /// Writes the Markdown to the pasteboard; false when it could not.
    let copy: (String) -> Bool
    /// Saves the Markdown as a note; nil where there are no notes to save
    /// into.
    let save: (() -> Bool)?
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            if releases.isEmpty {
                ContentUnavailableView("No release notes", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(releases) { release in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verbatim: release.version.description).font(.headline)
                                    Text(verbatim: Self.day(release)).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isHeader)
                                ForEach(Array(release.lines.enumerated()), id: \.offset) { _, line in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(verbatim: "•").accessibilityHidden(true)
                                        Text(verbatim: line.text).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
                }
            }
            Divider()
            HStack {
                Button("Copy") {
                    status = copy(ReleaseNotes.markdown(releases)) ? "Copied as Markdown." : "Could not copy."
                }
                if let save {
                    Button("Save as Note") {
                        status = save() ? "Saved as a note." : "Could not save the note."
                    }
                }
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .disabled(releases.isEmpty)
            .padding(12)
        }
    }

    /// The release's day in the user's format.
    static func day(_ release: ReleaseNotes.Release) -> String {
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: release.day) else { return release.date }
        return date.formatted(date: .long, time: .omitted)
    }
}
