#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="app"
PACKAGE=0

if [[ "${1:-}" == "--sim" ]]; then TARGET="sim"; shift; fi
if [[ "${1:-}" == "--aarch64" ]]; then TARGET="aarch64"; shift; fi
if [[ "${1:-}" == "--device" ]]; then TARGET="device"; shift; fi
if [[ "${1:-}" == "--package" ]]; then PACKAGE=1; shift; fi

cd "$ROOT_DIR"
mkdir -p build

resolve_sdl_flags() {
    if command -v sdl2-config >/dev/null 2>&1; then
        echo "$(sdl2-config --cflags --libs) $(pkg-config --cflags --libs sdl2_ttf 2>/dev/null || true)"
        return 0
    fi
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists sdl2; then
        echo "$(pkg-config --cflags --libs sdl2) $(pkg-config --cflags --libs sdl2_ttf 2>/dev/null || true)"
        return 0
    fi
    return 1
}

COMMON_SOURCES=(
    main/src/application.cpp
    main/src/config.cpp
    main/src/pwnagotchi_client.cpp
)

if [[ "$TARGET" == "sim" ]]; then
    SDL_FLAGS="$(resolve_sdl_flags)"
    clang++ -std=c++17 -Wall -Wextra -O2 \
        -Imain/include \
        "${COMMON_SOURCES[@]}" \
        main/src/hal_sdl.cpp \
        main/src/text_renderer_sdl.cpp \
        main/src/ui_sdl.cpp \
        main/src/main_sim.cpp \
        ${SDL_FLAGS} \
        -o build/pwnagotchi_simulator
elif [[ "$TARGET" == "aarch64" ]]; then
    env \
        ZIG_GLOBAL_CACHE_DIR="$ROOT_DIR/build/zig-cache-global" \
        ZIG_LOCAL_CACHE_DIR="$ROOT_DIR/build/zig-cache" \
        zig c++ -target aarch64-linux-gnu -std=c++17 -Wall -Wextra -Wno-nullability-completeness -O2 \
            -Imain/include \
            "${COMMON_SOURCES[@]}" \
            main/src/hal_stub.cpp \
            main/src/ui.cpp \
            main/src/main.cpp \
            -o build/pwnagotchi_app
    if [[ "$PACKAGE" == "1" ]]; then
        "$ROOT_DIR/tools/package_applaunch.sh"
    fi
elif [[ "$TARGET" == "device" ]]; then
    g++ -std=c++17 -Wall -Wextra -O2 \
        -Imain/include \
        "${COMMON_SOURCES[@]}" \
        main/src/display_bridge.cpp \
        main/src/hal_evdev.cpp \
        main/src/main_device.cpp \
        -o build/pwnagotchi_app
    if [[ "$PACKAGE" == "1" ]]; then
        "$ROOT_DIR/tools/package_applaunch.sh"
    fi
else
    g++ -std=c++17 -Wall -Wextra -O2 \
        -Imain/include \
        "${COMMON_SOURCES[@]}" \
        main/src/hal_stub.cpp \
        main/src/ui.cpp \
        main/src/main.cpp \
        -o build/pwnagotchi_app
fi
