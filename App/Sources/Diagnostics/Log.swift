import os

/// The app's `Logger`s, one category per area (#185), so Help ▸ Report a
/// Problem… has more than sync to show. Only what helps a report: outcomes,
/// counts, languages, kinds. Anything that could hold the user's text (an
/// error's description, a user script's name) is logged `.private`, which
/// the log store reads back as `<private>`.
enum Log {
    static let subsystem = "com.lemehmet.boopstash"
    static let store = Logger(subsystem: subsystem, category: "store")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let scripts = Logger(subsystem: subsystem, category: "scripts")
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
