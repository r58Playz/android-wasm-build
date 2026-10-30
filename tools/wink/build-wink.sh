#!/usr/bin/env bash
# build-wink.sh - Builds mesa-wink (https://github.com/MercuryWorkshop/mesa-wink, branch `wink`): Mesa's OpenGL on
# WebGPU, as static archives for an emscripten app. The Android runner is threaded (WasmEnableThreads), so the default
# variant is mt.
#
# Output: out/wink-<variant>.zip, wink's whole package (build/wink/out/<variant>/):
#   lib/libwink.a lib/libwink_webgpu.a lib/libwink_tint.a   mesa-wink (st/mesa + gex_wgpu + Tint + emdawnwebgpu)
#   js/*.js                    --js-library files; manifest.json's link.js_libraries is the order the link passes them
#   include/                   wink.h, wink_emscripten_compat.h, webgpu/webgpu.h
#   manifest.json wink.rsp wink.targets symbols/   link flags, response file, MSBuild import, exported symbols
#
# Compiled with upstream emsdk 3.1.56; the app links it with .NET's emsdk (wink/README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MESA_WINK_REPO="${MESA_WINK_REPO:-https://github.com/MercuryWorkshop/mesa-wink.git}"
MESA_WINK_REF="${MESA_WINK_REF:-3e705a4aaa27926d02bb6b788025af0af51e8c02}"
# Like IKVM_DIR, this can point at an existing working checkout.
WINK_SRC_DIR="${MESA_WINK_DIR:-$SCRIPT_DIR/mesa-wink}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"
VARIANT="${VARIANT:-mt}"

usage() {
    cat <<'USAGE'
Usage: build-wink.sh [options]

Options:
  --variant=<mt|st>     Build variant (default: mt).
  --wink-ref=<ref>      Initial mesa-wink git ref (default: the pinned commit, or $MESA_WINK_REF).
  --output-dir=<path>   Where wink-<variant>.zip goes (default: tools/wink/out).
  -h, --help            Show this help message.

Clones mesa-wink with full history into tools/wink/mesa-wink (or $MESA_WINK_DIR), starting its local wink branch at
the pinned ref. Existing checkouts are built as they stand, including local commits and edits; the ref only applies
when cloning. Install its host tools first: git, curl, cmake, ninja, bison >= 3, flex, and Python >= 3.10 with venv
support. Wink uses $EMSDK when set, and caches its build dependencies in ${XDG_CACHE_HOME:-~/.cache}/mesa-wink.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --wink-ref=*) MESA_WINK_REF="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$arg'" >&2; usage; exit 1 ;;
    esac
done

case "$VARIANT" in
    mt|st) ;;
    *) echo "ERROR: --variant must be mt or st (got '$VARIANT')" >&2; exit 1 ;;
esac

log() {
    echo "[build-wink/$VARIANT] $*"
}

for cmd in git python3 zip; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' not found" >&2; exit 1; }
done

if [ ! -e "$WINK_SRC_DIR/.git" ]; then
    log "Cloning mesa-wink @ $MESA_WINK_REF"
    git clone --no-checkout --branch wink "$MESA_WINK_REPO" "$WINK_SRC_DIR"
    git -C "$WINK_SRC_DIR" checkout -B wink "$MESA_WINK_REF"
else
    log "mesa-wink source already present, using working checkout."
fi
WINK_HEAD="$(git -C "$WINK_SRC_DIR" rev-parse HEAD)"
log "Building mesa-wink's working checkout @ ${WINK_HEAD:0:12} (initial pin: $MESA_WINK_REF)"
if [ -n "$(git -C "$WINK_SRC_DIR" status --porcelain --untracked-files=no)" ]; then
    log "  with uncommitted changes"
fi

bash "$WINK_SRC_DIR/wink/build.sh" --variant="$VARIANT"
WINK_OUT="$WINK_SRC_DIR/build/wink/out/$VARIANT"

if [ ! -f "$WINK_OUT/manifest.json" ]; then
    echo "ERROR: mesa-wink build did not produce $WINK_OUT/manifest.json." >&2
    exit 1
fi
WINK_VARIANT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("variant",""))' "$WINK_OUT/manifest.json")"
if [ -n "$WINK_VARIANT" ] && [ "$WINK_VARIANT" != "$VARIANT" ]; then
    echo "ERROR: $WINK_OUT is wink's '$WINK_VARIANT' build, not '$VARIANT'" >&2
    exit 1
fi
for a in libwink.a libwink_webgpu.a libwink_tint.a; do
    if [ ! -f "$WINK_OUT/lib/$a" ]; then
        echo "ERROR: expected wink archive not found: $WINK_OUT/lib/$a" >&2
        exit 1
    fi
done

mkdir -p "$OUTPUT_DIR"
OUTPUT_ZIP="$(cd "$OUTPUT_DIR" && pwd)/wink-$VARIANT.zip"
rm -f "$OUTPUT_ZIP"
(cd "$WINK_OUT" && zip -q -r "$OUTPUT_ZIP" .)

log "Wrote $OUTPUT_ZIP"
ls -lh "$OUTPUT_ZIP"
