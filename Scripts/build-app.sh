#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/CodexNotch.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/ModuleCache"
FALLBACK_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ -n "${CODEXNOTCH_SDK_PATH:-}" ]]; then
    SDK_PATH="$CODEXNOTCH_SDK_PATH"
elif [[ -d "$FALLBACK_SDK" ]]; then
    SDK_PATH="$FALLBACK_SDK"
else
    SDK_PATH="$(xcrun --show-sdk-path)"
fi

cd "$PROJECT_DIR"
mkdir -p "$MODULE_CACHE_DIR"
env \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR" \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
    SDKROOT="$SDK_PATH" \
    swift build --sdk "$SDK_PATH" -c release

mkdir -p "$MACOS_DIR"
cp "$PROJECT_DIR/.build/release/CodexNotch" "$MACOS_DIR/CodexNotch"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/CodexNotch"

/usr/bin/codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"

if [[ "${CODEXNOTCH_INSTALL:-0}" == "1" ]]; then
    "$PROJECT_DIR/Scripts/install-app.sh" "$APP_DIR"
else
    echo "仅完成构建；未修改 /Applications 或登录启动项。"
    echo "如需安装，请显式运行：CODEXNOTCH_INSTALL=1 ./Scripts/build-app.sh"
fi
