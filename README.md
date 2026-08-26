# Codex Notch

Codex Notch is an experimental native macOS companion that turns the display notch or menu bar into a compact status surface for local and connected Codex tasks.

> **Unofficial project.** This repository is not affiliated with, maintained by, or endorsed by OpenAI. Codex and OpenAI are names and marks of their respective owner.

> **Review status.** The code is being prepared for portfolio review. No open-source license has been granted yet; see [License and reuse](#license-and-reuse).

## Ownership and evidence boundary

This is an independent experimental project. I defined the low-interruption status experience, task-state model, privacy boundary, synthetic QA approach, and safe installation behavior. AI coding agents supported implementation and review under my direction; I reviewed changes and verified the public snapshot with synthetic data and CI.

The project depends on undocumented local Codex implementation details and may require adaptation after product updates. It demonstrates native product prototyping and systems reasoning, not external adoption or an official OpenAI integration.

## What it demonstrates

- A low-interruption notch lens that expands into a native task dashboard.
- Local, attention-required, failed, recently completed, and connected-Mac task states.
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
                  normalized task + quota models
                              │
                         AppModel state
                              │
             SwiftUI dashboard + AppKit notch panel
                              │
        Codex deep link or opt-in Accessibility navigation
```

The project keeps data acquisition, normalized domain state, application coordination, and presentation in separate targets and types:

- `CodexNotchCore` contains task models, grouping rules, quota parsing, retention rules, and read-only local repositories.
- `CodexNotch` owns lifecycle coordination, local IPC, the Codex App Server subprocess, SwiftUI views, and AppKit presentation.
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
swift test
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

Codex Notch processes task metadata on the Mac. It does not include analytics, telemetry, or a project-operated backend. It reads selected local Codex stores in read-only mode and keeps normalized task state in memory. It does not read or retain prompt previews or first-user-message fields.

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
