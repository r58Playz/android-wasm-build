#!/usr/bin/env bash
# build.sh - Builds the androidx Material 3 Catalog (an R8 release build) for the Android runner.
#
# The wrapper project here (app/, catalog/) builds the catalog library's sources from a sparse androidx checkout at a
# pinned commit (androidx/, fetched on first run), against one pinned androidx.dev snapshot build
# (settings.gradle.kts). Needs JDK 21 and an Android SDK ($ANDROID_HOME) with platforms;android-37.1; AGP fetches
# the rest.
#
# Output in out/: catalog-release.apk, catalog-release-mapping.txt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ANDROIDX_REPO="${ANDROIDX_REPO:-https://github.com/androidx/androidx.git}"
# androidx-main, 2026-10-26 22:42 PDT: the snapshot build's sources
ANDROIDX_REF="${ANDROIDX_REF:-b17c8cefef7fda4e51daadc540bdb308bc55f7c3}"
ANDROIDX_DIR="$SCRIPT_DIR/androidx"
CATALOG_DIR="compose/material3/material3/integration-tests/material3-catalog"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/out}"

log() {
    echo "[build-catalog] $*"
}

if [ "$(git -C "$ANDROIDX_DIR" rev-parse HEAD 2>/dev/null)" != "$ANDROIDX_REF" ]; then
    log "Fetching androidx @ $ANDROIDX_REF ($CATALOG_DIR only)"
    rm -rf "$ANDROIDX_DIR"
    git init -q "$ANDROIDX_DIR"
    git -C "$ANDROIDX_DIR" remote add origin "$ANDROIDX_REPO"
    git -C "$ANDROIDX_DIR" sparse-checkout set --cone "$CATALOG_DIR"
    git -C "$ANDROIDX_DIR" fetch -q --depth 1 --filter=blob:none origin "$ANDROIDX_REF"
    git -C "$ANDROIDX_DIR" checkout -q FETCH_HEAD
fi

cd "$SCRIPT_DIR"
./gradlew --no-daemon :app:assembleRelease

mkdir -p "$OUTPUT_DIR"
cp app/build/outputs/apk/release/app-release.apk "$OUTPUT_DIR/catalog-release.apk"
cp app/build/outputs/mapping/release/mapping.txt "$OUTPUT_DIR/catalog-release-mapping.txt"
log "Wrote $OUTPUT_DIR/catalog-release.apk"
ls -lh "$OUTPUT_DIR"
