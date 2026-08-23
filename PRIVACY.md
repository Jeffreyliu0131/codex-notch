# Privacy boundary

Codex Notch is designed as a local macOS status surface. It has no analytics SDK, telemetry pipeline, advertising identifier, or project-operated backend.

## Data read locally

Depending on the enabled feature and installed Codex version, the app may read or communicate with:

- `~/.codex/state_5.sqlite` through `/usr/bin/sqlite3 -readonly` for task identifiers, display titles, workspace paths, repository origins, model metadata, timestamps, and task state inputs;
- rollout lifecycle files and writer-lock filenames to distinguish active and completed work;
- `~/.codex/.codex-global-state.json` for task summaries already synchronized by the Codex desktop application from a connected Mac;
- `~/.codex/ipc/ipc.sock` for local runtime-state calibration;
- the locally installed `codex app-server --stdio` process for quota and runtime status.

The local repository intentionally does not select or retain the task `preview` or `first_user_message` fields.

## How data is used

Task titles, project folder names, state labels, device labels, and quota status are rendered in the notch or menu-bar interface. Repository origins and full paths may be used in memory to group tasks, while the interface normally presents the final folder or repository name.

Normalized task state is kept in process memory. The app does not create a secondary task database or upload a copy of task metadata to a service operated by this project.

Synthetic preview commands use hard-coded demonstration records under `/Users/demo/Projects/...`; they do not read real task data or capture the desktop.

## Network boundary

This repository does not implement a standalone remote network client. It starts the user's installed Codex App Server locally. That OpenAI-provided component may perform its ordinary account and network operations under the user's existing Codex configuration. Those operations are outside this project's implementation and privacy policy.

## Accessibility permission

Opening a task that belongs to a connected Mac may require macOS Accessibility permission. When the user invokes that action, the app may inspect the accessibility tree of the Codex desktop application and press the matching task control. It does not use Accessibility to capture screen pixels or inspect unrelated applications.

## Logging

Operational logs do not intentionally include task titles, prompts, workspace paths, or raw host and thread identifiers. Synthetic preview commands may print only the destination path explicitly supplied by the user.

## Installation files

The default build remains inside the repository. When installation is explicitly enabled with `CODEXNOTCH_INSTALL=1`, the installer writes:

- `/Applications/CodexNotch.app`;
- `~/Library/LaunchAgents/com.example.codexnotch.plist`.

Removing those two items and stopping the associated LaunchAgent removes the files installed by the project. The installer does not remove or modify the user's Codex data.
