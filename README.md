# Codex Notch

Codex Notch is an experimental native macOS companion that turns the display notch or menu bar into a compact status surface for local and connected Codex tasks.

> **Unofficial project.** This repository is not affiliated with, maintained by, or endorsed by OpenAI. Codex and OpenAI are names and marks of their respective owner.

> **Review status.** This is a public portfolio snapshot. No open-source license has been granted; see [License and reuse](#license-and-reuse).

## Ownership and evidence boundary

This is an independent experimental project. I defined the low-interruption status experience, task-state model, privacy boundary, synthetic QA approach, and safe installation behavior. AI coding agents supported implementation and review under my direction; I reviewed changes and verified the public snapshot with synthetic data and CI.

The project depends on undocumented local Codex implementation details and may require adaptation after product updates. It demonstrates native product prototyping and systems reasoning, not external adoption or an official OpenAI integration.

This public release was reconciled from the locally validated runtime source at `CodexNotch@4f9e514` (2026-09-01). The public repository keeps an independent, safety-reviewed history instead of mirroring the runtime working directory.

## What it demonstrates

- A low-interruption notch lens that expands into a native task dashboard.
- Local, approval-required, other-input, failed, recently completed, and connected-Mac task states.
- Explicit approval detection across structured runtime flags, local thread snapshots, and rollout fallback signals.
- An eight-second notch expansion plus a silent macOS notification when an approval is required and Codex is not frontmost.
- Alert deduplication that avoids replaying the same approval signal after refreshes or relaunches.
- Project grouping across Git worktrees and ordinary folders.
- Weekly quota status through the locally installed Codex App Server.
- A menu-bar fallback for Macs without a display notch.
- Native SwiftUI presentation coordinated with AppKit windows, menus, screen detection, and accessibility navigation.
- Synthetic off-screen preview modes for repeatable visual QA without capturing the desktop.

## Architecture

```text
Codex local state / rollout files / local IPC / local App Server
                              │
                     repository adapters
                              │
             normalized task + attention + quota models
                              │
                         AppModel state
                              │
       SwiftUI dashboard + AppKit notch panel + local alerts
                              │
        Codex deep link or opt-in Accessibility navigation
```

The project keeps data acquisition, normalized domain state, application coordination, and presentation in separate targets and types:

- `CodexNotchCore` contains task models, grouping rules, quota parsing, approval classification, alert deduplication, retention rules, and read-only local repositories.
- `CodexNotch` owns lifecycle coordination, local IPC, the Codex App Server subprocess, SwiftUI views, AppKit presentation, and macOS notification delivery.
- `CodexNotchSelfTest` exercises synthetic fixtures by default. Reading a real local Codex database is an explicit opt-in integration check.

## Requirements

- macOS 14 or later.
- Apple Command Line Tools or Xcode with Swift Package Manager.
- The Codex desktop application for live task status and navigation.

## Build

The default command only builds and ad-hoc signs `dist/CodexNotch.app` inside the repository:

```bash
./Scripts/build-app.sh
```

It does **not** modify `/Applications`, stop a running app, or register a login item.

## Explicit installation

Installation is intentionally opt-in:

```bash
CODEXNOTCH_INSTALL=1 ./Scripts/build-app.sh
```

That command replaces `/Applications/CodexNotch.app`, stops an existing CodexNotch process when necessary, writes `com.example.codexnotch.plist` to `~/Library/LaunchAgents`, and starts the login item. Review `Scripts/install-app.sh` before running it.

## Tests

The default checks use synthetic data and do not read a real Codex task database:

```bash
./Scripts/test.sh
```

CI environments with a full Xcode toolchain can run the equivalent commands directly:

```bash
swift test --enable-swift-testing --disable-xctest
swift build
swift run CodexNotchSelfTest
```

An optional local integration check is available only when explicitly enabled:

```bash
CODEXNOTCH_RUN_LOCAL_INTEGRATION=1 swift run CodexNotchSelfTest
```

That opt-in check reads up to five rows from the current user's local Codex state database in read-only mode.

## Synthetic visual previews

After a debug build, the app can render representative states without capturing desktop content or reading real task data:

```bash
./.build/debug/CodexNotch --render-preview /tmp/codex-notch-preview.png
./.build/debug/CodexNotch --render-attention-preview /tmp/codex-notch-attention.png
./.build/debug/CodexNotch --render-completion-preview /tmp/codex-notch-completion.png
./.build/debug/CodexNotch --render-viewed-completion-preview /tmp/codex-notch-viewed-completion.png
./.build/debug/CodexNotch --render-idle-preview /tmp/codex-notch-idle.png
./.build/debug/CodexNotch --render-collapsed-preview /tmp/codex-notch-collapsed.png
```

## Privacy and permissions

Codex Notch processes task metadata on the Mac. It does not include analytics, telemetry, or a project-operated backend. It reads selected local Codex stores in read-only mode and keeps normalized task state in memory. It does not select or retain the database `preview` or `first_user_message` fields.

For approval detection, local Codex IPC or App Server responses may contain a thread snapshot or history. The classifier examines only structured request text and the latest final assistant message, in memory, to determine whether the user is being asked for explicit approval. That text is not logged, persisted, or included in notifications. Notifications contain the device label and task title; their hidden payload contains only the host and thread identifiers needed to reopen the task.

The app starts the user's locally installed Codex App Server to request quota and runtime status. This repository does not implement its own remote network client, but the installed Codex component may perform its normal OpenAI account and network activity.

Opening a connected-Mac task may request macOS Accessibility permission so the app can locate and press the matching control in the Codex desktop UI. That permission is requested at the moment the feature is used.

See [PRIVACY.md](PRIVACY.md) for the complete data boundary and [SECURITY.md](SECURITY.md) for responsible reporting guidance.

## Compatibility boundary

The local state schema, rollout lifecycle events, desktop IPC methods, App Server methods, and `codex://` deep links are implementation details of the installed Codex application rather than stable public APIs. A Codex update may require this project to fall back or adapt.

## Third-party provenance

This repository contains no third-party source files, binary dependencies, or downloaded visual assets. Its interface uses SwiftUI/AppKit primitives and SF Symbols supplied by macOS.

Product behavior was informed by publicly observable ideas from:

- [Notch Triage](https://github.com/0Hyacinth0/Notch-Triage), whose repository did not provide a root license when reviewed. No source was copied from it.
- [Notchi](https://github.com/sk-ruban/notchi), which is GPL-3.0 licensed. No source was copied, linked, or vendored from it.

## License and reuse

No `LICENSE` file is currently provided. Copyright is retained, and this review snapshot does not grant permission to copy, modify, distribute, sublicense, or reuse the code. A license decision must be made separately before presenting the project as open source.

## Audit follow-through · 2026-09-05

The primary job is noticing actionable task changes without repeated checking. Repository reads now run on a dedicated actor, with a single in-flight UI refresh, cancellation/generation checks that discard late results, and a bounded SQLite subprocess timeout. Stale snapshots are explicitly labeled; no task text or content telemetry was added. These changes are local to the public snapshot and are not yet exported into the separately owned runtime source.

Next evaluation: in an explicitly authorized local session, compare manual checking with the companion over matched synthetic task sequences. Record missed approvals, duplicate/false alerts, time to notice an actionable event, deliberate interruptions, and source-staleness recovery. Keep event IDs synthetic and collect no prompt text. Test source-format changes and unavailable IPC before claiming compatibility with another installed version. Live compatibility and external adoption remain unverified.

Local acceptance: synthetic timeout/repository tests, Swift build and self-test. Release/install/profile actions are separate and have not run as part of this audit repair.

Local verification on 2026-09-05: 13 Swift tests (including a synthetic slow-query deadline) and 41 self-checks passed. Local Codex database integration remained disabled.
