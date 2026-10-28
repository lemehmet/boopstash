import ProjectDescription

// The editor spike is its own Tuist project so the main project and its CI
// never see it. Milestone 1 only; the code is thrown away and the outcome is
// recorded in docs/adr/0006.
let tuist = Tuist(fullHandle: nil, project: .tuist())
