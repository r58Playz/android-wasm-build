#!/usr/bin/env bash
# build-libjvm-only.sh - rebuilds libjvm.a alone (IKVM's src/libjvm: the JVM_* functions IKVM.Runtime calls) and
# refreshes it in out/native and the release bundle. For iterating on libjvm; the full build is build-ikvm-local.sh.
# Needs emcc, em++ and emar on PATH, or EMSDK naming an emsdk 3.1.56 (android-wasm's statics/emsdk is one).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IKVM_DIR="${IKVM_DIR:-$SCRIPT_DIR/ikvm}"
OUT="$SCRIPT_DIR/out"
if ! command -v emcc >/dev/null && [ -n "${EMSDK:-}" ]; then
	export EM_CONFIG="$EMSDK/emscripten/.emscripten"
	export PATH="$EMSDK/emscripten:$PATH"
fi
IKVM_NATIVE_ONLY=libjvm NATIVE_JOBS="${NATIVE_JOBS:-4}" bash "$SCRIPT_DIR/build-ikvm-native.sh" "$IKVM_DIR" "$OUT"
(cd "$OUT/native" && zip -q "$OUT/release/ikvm-wasm-bundle.zip" libjvm.a)
echo "[libjvm-only] $(ls -la "$OUT/native/libjvm.a")"
