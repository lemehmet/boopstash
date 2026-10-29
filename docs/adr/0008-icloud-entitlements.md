# ADR 0008 — iCloud entitlements, only in provisioned builds

- **Status:** Accepted (2026-10-29)
- **Deciders:** boopstash maintainers
- **Refines:** ADR 0001 (privacy baseline), ADR 0002 (storage and sync), ADR 0004 (distribution)

## Context

ADR 0002 syncs notes and images through `CKSyncEngine` to the private
database of the app's iCloud container. ADR 0001 requires an ADR for every
new entitlement. CloudKit needs three:

- `com.apple.developer.icloud-container-identifiers` and
  `com.apple.developer.icloud-services` (`CloudKit`), for the container
  `iCloud.com.lemehmet.boopstash` only;
- `com.apple.developer.aps-environment`, because `CKSyncEngine` learns about
  changes from other devices through push notifications;
- `com.apple.developer.icloud-container-environment`, which Developer ID
  apps must set (to `Production`) for CloudKit.

These are restricted entitlements. macOS refuses to launch an app that claims
them without an embedded provisioning profile that grants them. Debug builds,
CI and the app test host are signed ad hoc or not at all, so they have no
profile.

CloudKit is reached through the system's `cloudd` daemon, not the app's own
sockets, so sync does not need `com.apple.security.network.client`. The app
still has no network entitlement.

## Decision

- **Two entitlement files.** `App/Boopstash.entitlements` (sandbox and
  user-selected files) is the default for every build.
  `App/BoopstashCloud.entitlements` adds the iCloud keys above and is used
  only by a build that also embeds a matching profile. The build setting
  `BOOPSTASH_ENTITLEMENTS` selects the file and `BOOPSTASH_PROFILE` names the
  profile. Their defaults keep Debug builds, CI and the test host on the file
  without iCloud, so they keep launching.
- **The two environments are build settings.** `BOOPSTASH_ICLOUD_ENVIRONMENT`
  and `BOOPSTASH_APS_ENVIRONMENT` are `Production` and `production` by
  default, as the Developer ID release needs. A build signed with a
  development profile to try sync sets `Development` and `development`. The
  CloudKit schema is created in Development by that first sync, then
  deployed to Production in the CloudKit Console before a release syncs.
- **The release workflow embeds the Developer ID profile**
  (`MACOS_DEVELOPER_ID_PROFILE_BASE64`). It refuses a profile that lacks the
  container, and it checks that the signed app has exactly the expected
  entitlements, as before. The script service keeps the sandbox and nothing
  else (ADR 0007).
- **An entitlement is permission, not activity.** The app does not create a
  `CKContainer` or `CKSyncEngine`, or ask for the account status, until the
  user turns on Sync with iCloud in Settings. It is off by default. With
  sync off, the app contacts nothing. A build without the iCloud
  entitlements (any build without a profile) shows sync as unavailable
  instead of failing.
- **iOS** gets the same keys with the App Group for the share extension in
  its own change (#66).

## Consequences

- Sync can only be tried in a provisioned build: the Homebrew release, the
  App Store build, or a local build signed with a development profile. Unit
  and app tests cover the Core sync model, not CloudKit itself.
- SECURITY.md now lists iCloud as the one remote endpoint and points to
  both entitlement files.
- Re-creating the App ID's capabilities makes the profile invalid. It has to
  be re-created and the secret replaced, and the release workflow's profile
  check names that case.
