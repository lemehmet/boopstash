import Foundation
import Testing
@testable import BoopstashCore

/// BoopStash ▸ Install Command Line Tool… (#212).
@Suite struct CommandLineInstallTests {
    typealias Install = CommandLineInstall
    let app = "/Applications/BoopStash.app"
    let helper = "/Applications/BoopStash.app/Contents/Helpers/boopstash"

    @Test func helperIsInsideTheApp() {
        #expect(Install.helperPath(appPath: app) == helper)
        #expect(Install.helperPath(appPath: "/Users/a/Applications/BoopStash.app/") == "/Users/a/Applications/BoopStash.app/Contents/Helpers/boopstash")
    }

    @Test func translocation() {
        #expect(Install.isTranslocated(appPath: "/private/var/folders/x/T/AppTranslocation/1234/d/BoopStash.app"))
        #expect(!Install.isTranslocated(appPath: app))
    }

    @Test func defaultFolderIsTheFirstThatExists() {
        let home = "/Users/a"
        #expect(Install.candidateFolders(home: home) == ["/opt/homebrew/bin", "/usr/local/bin", "/Users/a/.local/bin"])
        #expect(Install.defaultFolder(home: home) { _ in true } == "/opt/homebrew/bin")
        #expect(Install.defaultFolder(home: home) { $0 != "/opt/homebrew/bin" } == "/usr/local/bin")
        #expect(Install.defaultFolder(home: home) { $0.hasPrefix(home) } == "/Users/a/.local/bin")
        #expect(Install.defaultFolder(home: home) { _ in false } == nil)
    }

    @Test func plans() {
        let folder = "/opt/homebrew/bin"
        func plan(_ existing: Install.Existing) -> Install.Plan { Install.plan(existing: existing, folder: folder, helper: helper) }
        #expect(plan(.nothing) == .link)
        #expect(plan(.other) == .occupied)
        // The cask's link, absolute or relative, is this app's.
        #expect(plan(.link(destination: helper, resolves: true)) == .alreadyInstalled)
        #expect(plan(.link(destination: "../../../Applications/BoopStash.app/Contents/Helpers/boopstash", resolves: true)) == .alreadyInstalled)
        let other = "/Users/a/Applications/BoopStash.app/Contents/Helpers/boopstash"
        #expect(plan(.link(destination: other, resolves: true)) == .linkedElsewhere(other))
        #expect(plan(.link(destination: other, resolves: false)) == .replaceBroken)
        // Outside the grant the app cannot tell: never replace a maybe-working link.
        #expect(plan(.link(destination: other, resolves: nil)) == .linkedElsewhere(other))
        // A link to anything else is someone else's, broken or not.
        #expect(plan(.link(destination: "/usr/bin/true", resolves: true)) == .occupied)
        #expect(plan(.link(destination: "/gone/boopstash", resolves: false)) == .occupied)
        // Another app's helper of the same name is not ours either.
        #expect(plan(.link(destination: "/gone/Other.app/Contents/Helpers/boopstash", resolves: false)) == .occupied)
        #expect(plan(.link(destination: "/gone/BoopStash 2.app/Contents/Helpers/boopstash", resolves: false)) == .replaceBroken)
    }

    @Test func shellCommandQuotesPaths() {
        #expect(Install.shellCommand(helper: helper, folder: "/usr/local/bin")
            == "sudo ln -s '/Applications/BoopStash.app/Contents/Helpers/boopstash' '/usr/local/bin/boopstash'")
        #expect(Install.shellCommand(helper: "/Users/o'b/BoopStash.app/Contents/Helpers/boopstash", folder: "/usr/local/bin")
            == #"sudo ln -s '/Users/o'\''b/BoopStash.app/Contents/Helpers/boopstash' '/usr/local/bin/boopstash'"#)
        // A broken link is still there when the folder is root's: -f replaces it.
        #expect(Install.shellCommand(helper: helper, folder: "/usr/local/bin", replacing: true)
            == "sudo ln -sf '/Applications/BoopStash.app/Contents/Helpers/boopstash' '/usr/local/bin/boopstash'")
    }

    @Test func lookupErrors() {
        #expect(Install.found(lookupError: nil) == true)
        #expect(Install.found(lookupError: ENOENT) == false)
        #expect(Install.found(lookupError: ENOTDIR) == false)
        // The sandbox denies the read outside the panel's grant.
        #expect(Install.found(lookupError: EPERM) == nil)
        #expect(Install.found(lookupError: EACCES) == nil)
    }

    @Test func stillInstalled() {
        let folder = "/opt/homebrew/bin"
        func still(_ existing: Install.Existing?) -> Bool? { Install.stillInstalled(existing: existing, folder: folder, helper: helper) }
        #expect(still(.link(destination: helper, resolves: true)) == true)
        #expect(still(.link(destination: helper, resolves: nil)) == true)
        // Unreadable after a relaunch: unknown.
        #expect(still(nil) == nil)
        // Removed, uninstalled, replaced, or the app moved.
        #expect(still(.nothing) == false)
        #expect(still(.other) == false)
        #expect(still(.link(destination: "/Users/a/Applications/BoopStash.app/Contents/Helpers/boopstash", resolves: true)) == false)
        #expect(still(.link(destination: "/Users/a/Applications/BoopStash.app/Contents/Helpers/boopstash", resolves: false)) == false)
    }
}
