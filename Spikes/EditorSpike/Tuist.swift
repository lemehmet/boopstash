import ProjectDescription

// The editor spike is its own Tuist project so the main project and its CI
// never see it. It is kept as the evidence behind docs/adr/0006: rerun its
// checks before changing a conclusion there. The app does not import it.
let tuist = Tuist(fullHandle: nil, project: .tuist())
