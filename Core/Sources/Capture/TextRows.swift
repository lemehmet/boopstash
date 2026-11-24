import Foundation

/// A piece of text a recogniser found in a picture, and where.
public struct TextObservation: Equatable, Sendable {
    public var text: String
    /// Its box in the picture: origin at the top left, y growing downwards,
    /// in one unit for both axes (pixels), so a gap can be compared with a
    /// height.
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Recognised text laid out the way it reads in the picture (#243). A
/// recogniser returns one observation per run of text, so a screenshot of
/// a table arrives as one cell after another; here the observations on one
/// visual row become one line.
public enum TextRows {
    /// A gap wider than this many text heights separates cells with a tab;
    /// a narrower one is a space between words.
    public static let wideGap: CGFloat = 1

    /// The observations' text: rows from top to bottom, each row's pieces
    /// from left to right, joined by a tab across a wide gap and a space
    /// otherwise. The order the observations come in does not matter.
    public static func text(from observations: [TextObservation]) -> String {
        let usable = observations
            .filter { !$0.text.isEmpty && $0.box.height > 0 }
            .sorted { ($0.box.midY, $0.box.minX) < ($1.box.midY, $1.box.minX) }
        // Each row is anchored on its first (topmost) box. A box joins a row
        // when each of the two centres lies within the other's height: a
        // slightly skewed baseline still matches, while a tall box beside
        // two short lines does not swallow them both. Comparing with the
        // anchor, not the last box added, keeps a skew from walking a row
        // down into the next one.
        var rows: [[TextObservation]] = []
        for observation in usable {
            if let index = rows.lastIndex(where: { sameRow($0[0].box, observation.box) }) {
                rows[index].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.map(line).joined(separator: "\n")
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        a.midY > b.minY && a.midY < b.maxY && b.midY > a.minY && b.midY < a.maxY
    }

    private static func line(_ row: [TextObservation]) -> String {
        let cells = row.sorted { $0.box.minX < $1.box.minX }
        var line = cells[0].text
        // The right edge so far, so a box inside or overlapping the one
        // before it is measured from where the text really ends.
        var edge = cells[0].box.maxX
        var height = cells[0].box.height
        for cell in cells.dropFirst() {
            let gap = cell.box.minX - edge
            line += gap > wideGap * min(height, cell.box.height) ? "\t" : " "
            line += cell.text
            edge = max(edge, cell.box.maxX)
            height = cell.box.height
        }
        return line
    }
}
