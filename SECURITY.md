# Security policy

## Project status

Codex Notch is an experimental portfolio-review project. It depends on local implementation details of the Codex desktop application and has not received an independent security audit.

## Reporting a vulnerability

Please report suspected vulnerabilities through the repository's private GitHub Security Advisory flow. Do not open a public issue for a vulnerability before a fix or mitigation is available.

When reporting, include:

- the affected commit and macOS version;
- the smallest reproducible sequence;
- the expected and observed behavior;
- whether local Codex task data, Accessibility permission, the login item, or app-server communication is involved.

Do not attach a real `state_5.sqlite`, `.codex-global-state.json`, rollout file, task title, thread identifier, workspace path, screenshot, or log containing personal task data. Replace those values with synthetic fixtures.

## Sensitive surfaces

Security review should pay particular attention to:

- read-only access to local Codex state and rollout files;
- the local Codex IPC socket, App Server subprocess, and in-memory approval classifier;
- macOS notification content, hidden payload minimization, and the hashed approval-alert ledger;
- task deep links and Accessibility-based navigation;
- replacement of `/Applications/CodexNotch.app` during explicit installation;
- the per-user LaunchAgent created by the explicit installer.

The default build path does not install or start the app. Installation requires `CODEXNOTCH_INSTALL=1`.

## Supported versions

Only the latest repository revision is considered for security fixes while the project remains experimental.
