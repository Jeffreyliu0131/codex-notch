#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE_APP="${1:-$PROJECT_DIR/dist/CodexNotch.app}"
INSTALL_APP="/Applications/CodexNotch.app"
INSTALL_BINARY="$INSTALL_APP/Contents/MacOS/CodexNotch"
DIST_BINARY="$PROJECT_DIR/dist/CodexNotch.app/Contents/MacOS/CodexNotch"
RELEASE_BINARY="$PROJECT_DIR/.build/release/CodexNotch"
DEBUG_BINARY="$PROJECT_DIR/.build/debug/CodexNotch"
LAUNCH_AGENT_LABEL="com.example.codexnotch"
LAUNCH_AGENT_SOURCE="$PROJECT_DIR/Resources/$LAUNCH_AGENT_LABEL.plist"
LAUNCH_AGENT_DIRECTORY="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_DESTINATION="$LAUNCH_AGENT_DIRECTORY/$LAUNCH_AGENT_LABEL.plist"
LAUNCH_DOMAIN="gui/$(id -u)"

if [[ ! -x "$SOURCE_APP/Contents/MacOS/CodexNotch" ]]; then
    echo "找不到可安装的 CodexNotch.app: $SOURCE_APP" >&2
    exit 1
fi

mkdir -p "$LAUNCH_AGENT_DIRECTORY"
launchctl bootout "$LAUNCH_DOMAIN/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true

for pid in $(pgrep -x CodexNotch 2>/dev/null || true); do
    command_path="$(ps -p "$pid" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$command_path" == "$INSTALL_BINARY" \
        || "$command_path" == "$DIST_BINARY" \
        || "$command_path" == "$RELEASE_BINARY" \
        || "$command_path" == "$RELEASE_BINARY "* \
        || "$command_path" == "$DEBUG_BINARY" \
        || "$command_path" == "$DEBUG_BINARY "* \
        || "$command_path" == "./.build/release/CodexNotch"* \
        || "$command_path" == "./.build/debug/CodexNotch"* ]]; then
        kill "$pid" 2>/dev/null || true
    fi
done

for _ in {1..30}; do
    has_old_process=false
    for pid in $(pgrep -x CodexNotch 2>/dev/null || true); do
        command_path="$(ps -p "$pid" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ "$command_path" == "$INSTALL_BINARY" \
            || "$command_path" == "$DIST_BINARY" \
            || "$command_path" == "$RELEASE_BINARY" \
            || "$command_path" == "$RELEASE_BINARY "* \
            || "$command_path" == "$DEBUG_BINARY" \
            || "$command_path" == "$DEBUG_BINARY "* \
            || "$command_path" == "./.build/release/CodexNotch"* \
            || "$command_path" == "./.build/debug/CodexNotch"* ]]; then
            has_old_process=true
            break
        fi
    done
    [[ "$has_old_process" == false ]] && break
    sleep 0.1
done

for pid in $(pgrep -x CodexNotch 2>/dev/null || true); do
    command_path="$(ps -p "$pid" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$command_path" == "$INSTALL_BINARY" \
        || "$command_path" == "$DIST_BINARY" \
        || "$command_path" == "$RELEASE_BINARY" \
        || "$command_path" == "$RELEASE_BINARY "* \
        || "$command_path" == "$DEBUG_BINARY" \
        || "$command_path" == "$DEBUG_BINARY "* \
        || "$command_path" == "./.build/release/CodexNotch"* \
        || "$command_path" == "./.build/debug/CodexNotch"* ]]; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
done

/usr/bin/ditto --rsrc --extattr "$SOURCE_APP" "$INSTALL_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
/usr/bin/install -m 644 "$LAUNCH_AGENT_SOURCE" "$LAUNCH_AGENT_DESTINATION"

launchctl bootstrap "$LAUNCH_DOMAIN" "$LAUNCH_AGENT_DESTINATION"
launchctl enable "$LAUNCH_DOMAIN/$LAUNCH_AGENT_LABEL"
launchctl kickstart -k "$LAUNCH_DOMAIN/$LAUNCH_AGENT_LABEL"

echo "已安装并启动：$INSTALL_APP"
echo "登录启动项：$LAUNCH_AGENT_DESTINATION"
