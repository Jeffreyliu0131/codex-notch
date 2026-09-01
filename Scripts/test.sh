#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/ModuleCache"

cd "$PROJECT_DIR"
mkdir -p "$MODULE_CACHE_DIR"

env \
    CODEXNOTCH_USE_CLT_TESTING=1 \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR" \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
    swift test \
        --disable-sandbox \
        --enable-swift-testing \
        --disable-xctest \
        -Xswiftc -F \
        -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks

env \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR" \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
    swift run --disable-sandbox CodexNotchSelfTest
