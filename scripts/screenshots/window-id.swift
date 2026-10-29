import CoreGraphics
// The demo app's windows: number, width, height, x, y (points, from the
// top left of the main display).
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "BoopStash" && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String]!, b["Width"]!, b["Height"]!, b["X"]!, b["Y"]!)
}
