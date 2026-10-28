#!/usr/bin/env bash
# build-ikvm-local.sh - Builds IKVM managed libraries and WASM native artifacts.
# Shared by local runs and GitHub Actions.

set -euo pipefail

# The WASM fork of IKVM. Its `android` branch is its `wasm` branch (what used to live in ikvm.patch, as individually
# described commits on top of ikvmnet/ikvm main) plus the Android runner's runtime work.
IKVM_REPO="${IKVM_REPO:-https://github.com/r58playz/ikvm.git}"
IKVM_REF="${IKVM_REF:-android}"
# Version stamp for the assemblies; unrelated to IKVM_REF, which is now a branch name
# and not a valid semver.
IKVM_VERSION="${IKVM_VERSION:-8.14.0}"
# Must satisfy the checkout's global.json sdk pin (10.0.x on the fork's base).
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
NATIVE_SDK_VERSION="${NATIVE_SDK_VERSION:-20251124.1}"
EMSDK_VERSION="${EMSDK_VERSION:-3.1.56}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"
# Where the fork gets cloned. Override to build from an existing checkout.
IKVM_DIR="${IKVM_DIR:-$WORKSPACE/ikvm}"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_RUNTIME="${BUILD_RUNTIME:-linux-x64}"
ENABLED_RUNTIMES="${ENABLED_RUNTIMES:-$BUILD_RUNTIME}"
ENABLED_IMAGE_RUNTIMES="${ENABLED_IMAGE_RUNTIMES:-$BUILD_RUNTIME}"
ENABLED_IMAGE_BIN_RUNTIMES="${ENABLED_IMAGE_BIN_RUNTIMES:-$BUILD_RUNTIME}"
ENABLED_TOOL_RUNTIMES="${ENABLED_TOOL_RUNTIMES:-$BUILD_RUNTIME}"
CLANG_COMPAT_FLAGS="${CLANG_COMPAT_FLAGS:-}"

# ── Argument parsing ──────────────────────────────────────────────────────────

SKIP_MANAGED=false
SKIP_NATIVE=false
SKIP_BUNDLE=false
CLEAN_NATIVE=false
for arg in "$@"; do
    case "$arg" in
        --skip-managed) SKIP_MANAGED=true ;;
        --skip-native) SKIP_NATIVE=true ;;
        --skip-bundle) SKIP_BUNDLE=true ;;
        --managed-only)
            SKIP_NATIVE=true
            SKIP_BUNDLE=true
            ;;
        --native-only)
            SKIP_MANAGED=true
            SKIP_BUNDLE=true
            ;;
        --clean-native) CLEAN_NATIVE=true ;;
        *) echo "ERROR: unknown argument '$arg'" >&2; exit 1 ;;
    esac
done

# The fork builds into artifacts/jdk25 (its IkvmArtifactsDir).
IKVM_ARTIFACTS_DIR="$IKVM_DIR/artifacts/jdk25"
OUT_BASE="$WORKSPACE/out"

# The native static libraries the bundle has. JDK 25 has no libsunec (EC is Java since JDK 22) or libunpack (no pack200
# since JDK 14); its JPEG library is libjavajpeg; libawt_headless and libprefs are their own libraries; libmanagement and
# libmanagement_ext are IKVM's JNI_OnLoad only.
NATIVE_LIBS=(libjvm libikvm libiava libzip libnet libnio libprefs libmanagement libmanagement_ext libjavajpeg
    libmlib_image liblcms libawt libawt_headless libfontmanager libfreetype)

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[build-ikvm-local] $*"; }

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: required command '$1' not found" >&2
        exit 1
    fi
}

# The tools are ikvmc's publish, which the class library's build makes. The TFM it is published under tracks whatever
# upstream currently builds it for (net8.0 up to 8.14.0, net10.0 since) and is independent of the net8.0 JRE image, so
# discover it rather than pinning it. Highest version wins.
find_tools_dist_dir() {
    local d newest="" a b
    for d in "$IKVM_ARTIFACTS_DIR"/bin/ikvmc/Release/*/"$BUILD_RUNTIME"/publish; do
        [ -d "$d" ] || continue
        if [ -z "$newest" ]; then
            newest="$d"
            continue
        fi
        a="$(basename "$(dirname "${d%/publish}")")"
        b="$(basename "$(dirname "${newest%/publish}")")"
        if [ "$(printf '%s\n%s\n' "${a#net}" "${b#net}" | sort -V | tail -1)" = "${a#net}" ]; then
            newest="$d"
        fi
    done
    printf '%s' "$newest"
}

# RuntimeIdentifier adds a directory before ikvm; prefer that build over output
# left by a build without a runtime identifier.
find_image_dir() {
    local base="$IKVM_ARTIFACTS_DIR/bin/IKVM.Image/Release/net8.0"
    local image
    for image in "$base/$BUILD_RUNTIME/ikvm/$BUILD_RUNTIME" "$base/ikvm/$BUILD_RUNTIME"; do
        if [ -d "$image" ]; then
            printf '%s' "$image"
            return 0
        fi
    done
    echo "ERROR: $BUILD_RUNTIME JRE image not found. Checked:" >&2
    printf '       %s\n' "$base/$BUILD_RUNTIME/ikvm/$BUILD_RUNTIME" "$base/ikvm/$BUILD_RUNTIME" >&2
    return 1
}

add_unique_asset() {
    local asset="$1"
    if [ -z "${NATIVE_SDK_ASSET_SEEN[$asset]+x}" ]; then
        NATIVE_SDK_ASSETS+=("$asset")
        NATIVE_SDK_ASSET_SEEN["$asset"]=1
    fi
}

collect_native_sdk_assets() {
    local runtime_list="$1"
    local tokenized
    local runtime

    NATIVE_SDK_ASSETS=()
    declare -gA NATIVE_SDK_ASSET_SEEN=()

    tokenized="${runtime_list//,/;}"
    IFS=';' read -r -a _runtimes <<< "$tokenized"
    for runtime in "${_runtimes[@]}"; do
        runtime="${runtime//[[:space:]]/}"
        [ -n "$runtime" ] || continue
        case "$runtime" in
            linux-arm) add_unique_asset "linux-arm.tar.gz" ;;
            linux-arm64) add_unique_asset "linux-arm64.tar.gz" ;;
            linux-musl-arm) add_unique_asset "linux-musl-arm.tar.gz" ;;
            linux-musl-arm64) add_unique_asset "linux-musl-arm64.tar.gz" ;;
            linux-musl-x64) add_unique_asset "linux-musl-x64.tar.gz" ;;
            linux-x64) add_unique_asset "linux-x64.tar.gz" ;;
            osx*|macos*) add_unique_asset "osx.tar.gz" ;;
            win*|windows*) add_unique_asset "win.tar.gz" ;;
        esac
    done

    if [ "${#NATIVE_SDK_ASSETS[@]}" -eq 0 ]; then
        NATIVE_SDK_ASSETS=(
            linux-arm.tar.gz
            linux-arm64.tar.gz
            linux-musl-arm.tar.gz
            linux-musl-arm64.tar.gz
            linux-musl-x64.tar.gz
            linux-x64.tar.gz
            osx.tar.gz
            win.tar.gz
        )
    fi
}

# The bundle's managed assemblies, from the build of their projects.
copy_managed_outputs() {
    local dest="$1"
    local bin="$IKVM_ARTIFACTS_DIR/bin" bytecode project name built candidate
    # a project's output is under the runtime identifier's directory when its build had one (this script's does) and
    # directly under net8.0 when not (a build of the project alone): the newer is this build's
    for project in IKVM.Runtime:IKVM.CoreLib IKVM.Runtime:IKVM.Runtime IKVM.Java.runtime.linux:IKVM.Java; do
        name="${project#*:}"
        project="${project%%:*}"
        built=""
        for candidate in "$bin/$project/Release/net8.0/$name.dll" "$bin/$project/Release/net8.0/"*/"$name.dll"; do
            [ -f "$candidate" ] || continue
            if [ -z "$built" ] || [ "$candidate" -nt "$built" ]; then
                built="$candidate"
            fi
        done
        if [ -z "$built" ]; then
            echo "ERROR: $name.dll not found under $bin/$project/Release/net8.0" >&2
            exit 1
        fi
        cp "$built" "$dest/"
    done
    # IKVM.ByteCode is a package; the version IKVM.Runtime references
    bytecode="$(ls -d "$NUGET_PACKAGES"/ikvm.bytecode/*/lib/net8.0/IKVM.ByteCode.dll 2>/dev/null | sort -V | tail -n 1)"
    if [ -z "$bytecode" ]; then
        echo "ERROR: IKVM.ByteCode not found in $NUGET_PACKAGES" >&2
        exit 1
    fi
    cp "$bytecode" "$dest/"
}

if [ "$SKIP_NATIVE" = "true" ] && [ "$CLEAN_NATIVE" = "true" ]; then
    log "Ignoring --clean-native because native build is skipped."
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────

require_cmd git
require_cmd curl
require_cmd zip
require_cmd tar

if [ "$SKIP_MANAGED" = "false" ]; then
    require_cmd mono

    # Locate clang/llvm-ar: prefer versioned (clang-20, llvm-ar-20), fall back to unversioned
    CLANG_EXE=""
    LLVM_AR_EXE=""
    for ver in 20 19 18 17 ""; do
        suffix="${ver:+-$ver}"
        if command -v "clang${suffix}" &>/dev/null; then
            CLANG_EXE="$(command -v "clang${suffix}")"
            break
        fi
    done
    for ver in 20 19 18 17 ""; do
        suffix="${ver:+-$ver}"
        if command -v "llvm-ar${suffix}" &>/dev/null; then
            LLVM_AR_EXE="$(command -v "llvm-ar${suffix}")"
            break
        fi
    done
    if [ -z "$CLANG_EXE" ] || [ -z "$LLVM_AR_EXE" ]; then
        echo "ERROR: clang and llvm-ar are required" >&2
        exit 1
    fi
    log "Using clang:   $CLANG_EXE"
    log "Using llvm-ar: $LLVM_AR_EXE"

    CLANG_MAJOR="$($CLANG_EXE -dumpversion 2>/dev/null | cut -d. -f1 || true)"
    if [ -z "$CLANG_COMPAT_FLAGS" ] && [[ "$CLANG_MAJOR" =~ ^[0-9]+$ ]] && [ "$CLANG_MAJOR" -ge 22 ]; then
        CLANG_COMPAT_FLAGS="-Wno-incompatible-pointer-types"
    fi
    if [ -n "$CLANG_COMPAT_FLAGS" ]; then
        log "Using additional Clang compile options: $CLANG_COMPAT_FLAGS"
    fi
fi

# ── .NET SDK setup ────────────────────────────────────────────────────────────
# IKVM's global.json pins the SDK feature band (rollForward: latestFeature): 9.0.x
# up to 8.14.0, 10.0.x on the fork's current base. Install it locally via
# dotnet-install.sh if the system doesn't have it.

if [ "$SKIP_MANAGED" = "false" ]; then

DOTNET_INSTALL_DIR="$REPO_ROOT/.dotnet"
DOTNET_INSTALL_SCRIPT="$REPO_ROOT/.dotnet-install.sh"

_dotnet_has_sdk() {
    # returns 0 if an SDK from the required channel is already reachable
    dotnet --list-sdks 2>/dev/null | grep -q "^${DOTNET_CHANNEL%%.*}\."
}

if ! _dotnet_has_sdk; then
    log "No .NET ${DOTNET_CHANNEL} SDK found – installing to $DOTNET_INSTALL_DIR ..."
    mkdir -p "$DOTNET_INSTALL_DIR"
    if [ ! -f "$DOTNET_INSTALL_SCRIPT" ]; then
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$DOTNET_INSTALL_SCRIPT"
        chmod +x "$DOTNET_INSTALL_SCRIPT"
    fi
    log "  Installing .NET ${DOTNET_CHANNEL} SDK ..."
    "$DOTNET_INSTALL_SCRIPT" --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_INSTALL_DIR" --no-path
    export DOTNET_ROOT="$DOTNET_INSTALL_DIR"
    export PATH="$DOTNET_INSTALL_DIR:$PATH"
else
    log "System .NET SDKs: $(dotnet --list-sdks 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
fi

if ! command -v dotnet &>/dev/null; then
    echo "ERROR: 'dotnet' not found even after local install" >&2
    exit 1
fi

fi # end SKIP_MANAGED=false

# ── Step 1: Clone IKVM source ─────────────────────────────────────────────────

if [ ! -d "$IKVM_DIR/.git" ]; then
    log "Cloning $IKVM_REPO @ $IKVM_REF ..."
    git clone \
        --recurse-submodules \
        --branch "$IKVM_REF" \
        "$IKVM_REPO" \
        "$IKVM_DIR"
else
    log "IKVM source already present, skipping clone."
fi

log "Updating IKVM submodules ..."
git -C "$IKVM_DIR" submodule update --init --recursive

# ── Step 2: Version environment variables ─────────────────────────────────────

VERSION="$IKVM_VERSION"
export GitVersion_FullSemVer="$VERSION"
export GitVersion_SemVer="$VERSION"
export GitVersion_AssemblySemVer="${VERSION}.0"
export GitVersion_AssemblySemFileVer="${VERSION}.0"
export GitVersion_InformationalVersion="$VERSION"
export GitVersion_PreReleaseLabel=""
export GitVersion_WeightedPreReleaseNumber="0"

if [ "$SKIP_MANAGED" = "false" ]; then

# ── Step 3: Download Native SDKs ─────────────────────────────────────────────

NATIVE_SDK_DIR="$IKVM_DIR/ext/ikvm-native-sdk"
mkdir -p "$NATIVE_SDK_DIR"

collect_native_sdk_assets "$ENABLED_RUNTIMES"
log "Native SDK runtime filters: $ENABLED_RUNTIMES"

RELEASE_BASE="https://github.com/ikvmnet/ikvm-native-sdk/releases/download/${NATIVE_SDK_VERSION}"
downloaded_any=false
for asset in "${NATIVE_SDK_ASSETS[@]}"; do
    marker="$NATIVE_SDK_DIR/.asset-${NATIVE_SDK_VERSION}-${asset}.ok"
    if [ -f "$marker" ]; then
        continue
    fi

    downloaded_any=true
    log "  Downloading $asset (tag $NATIVE_SDK_VERSION) ..."
    curl -fsSL -o "$NATIVE_SDK_DIR/$asset" "$RELEASE_BASE/$asset"
    tar xzf "$NATIVE_SDK_DIR/$asset" -C "$NATIVE_SDK_DIR"
    rm "$NATIVE_SDK_DIR/$asset"
    touch "$marker"
done

if [ "$downloaded_any" = "false" ]; then
    log "Native SDKs already downloaded for current runtime filters, skipping."
fi

# ── Step 4: NuGet Restore ─────────────────────────────────────────────────────

export NUGET_PACKAGES="${NUGET_PACKAGES:-$REPO_ROOT/.nuget/packages}"
log "Using NuGet package cache: $NUGET_PACKAGES"
log "Managed runtime filters: Enabled=$ENABLED_RUNTIMES Image=$ENABLED_IMAGE_RUNTIMES ImageBin=$ENABLED_IMAGE_BIN_RUNTIMES Tool=$ENABLED_TOOL_RUNTIMES"

RUNTIME_BUILD_PROPS=(
    "/p:EnabledRuntimes=$ENABLED_RUNTIMES"
    "/p:EnabledImageRuntimes=$ENABLED_IMAGE_RUNTIMES"
    "/p:EnabledImageBinRuntimes=$ENABLED_IMAGE_BIN_RUNTIMES"
    "/p:EnabledToolRuntimes=$ENABLED_TOOL_RUNTIMES"
    "/p:RuntimeIdentifier=$BUILD_RUNTIME"
    # dist-jre builds the whole managed stack once per JRE-image TFM. Only the
    # net8.0 image is consumed below, so skip the net6.0 image to avoid a full
    # duplicate compile of IKVM.Runtime/Java/CoreLib (roughly halves managed time).
    "/p:BuildNet6JreImages=false"
)

if [ -n "$CLANG_COMPAT_FLAGS" ]; then
    RUNTIME_BUILD_PROPS+=("/p:AdditionalCompileOptions=$CLANG_COMPAT_FLAGS")
fi

cd "$IKVM_DIR"

# IkvmToolReference is not a NuGet ProjectReference, so the class library's
# /restore does not visit ikvmc or ikvmstub. Restore them explicitly before any
# build can invoke GetPublishProjectPath from their IKVM.Core.MSBuild package.
log "Restoring IKVM tool projects ..."
for IKVM_TOOL_PROJECT in src/ikvmc/ikvmc.csproj src/ikvmstub/ikvmstub.csproj; do
    dotnet msbuild /t:Restore /nr:false \
        /p:Configuration="Release" \
        "${RUNTIME_BUILD_PROPS[@]}" \
        "$IKVM_TOOL_PROJECT"
done

# ── Step 5: Build Artifacts ───────────────────────────────────────────────────

# What the bundle takes (copy_managed_outputs, the image), each project restored as it is built: the solution's test
# projects target TFMs these do not have. The class library is compiled against the runtime's reference assembly, so
# the runtime builds on its own. The class library's build publishes ikvmc, which compiles it; the image's builds the
# natives of the desktop target as well.
IKVM_BUILD_PROJECTS=(
    src/IKVM.Runtime/IKVM.Runtime.csproj
    src/IKVM.Java.runtime.linux/IKVM.Java.runtime.linux.ikvmproj
    src/IKVM.Image/IKVM.Image.csproj
)

log "Building IKVM artifacts (this will take a while) ..."
mkdir -p "$IKVM_ARTIFACTS_DIR"
for IKVM_BUILD_PROJECT in "${IKVM_BUILD_PROJECTS[@]}"; do
dotnet msbuild /m "/bl:$IKVM_ARTIFACTS_DIR/msbuild-$(basename "$IKVM_BUILD_PROJECT").binlog" /nr:false /restore \
    /p:Configuration="Release" \
    /p:PreReleaseLabel="${GitVersion_PreReleaseLabel}" \
    /p:PreReleaseNumber="${GitVersion_WeightedPreReleaseNumber}" \
    /p:Version="${GitVersion_FullSemVer}" \
    /p:AssemblyVersion="${GitVersion_AssemblySemVer}" \
    /p:InformationalVersion="${GitVersion_InformationalVersion}" \
    /p:FileVersion="${GitVersion_AssemblySemFileVer}" \
    /p:PackageVersion="${GitVersion_FullSemVer}" \
    /p:RepositoryUrl="https://github.com/ikvmnet/ikvm.git" \
    /p:PackageProjectUrl="https://github.com/ikvmnet/ikvm" \
    /p:BuildInParallel=true \
    /p:CreateHardLinksForAdditionalFilesIfPossible=true \
    /p:CreateHardLinksForCopyAdditionalFilesIfPossible=true \
    /p:CreateHardLinksForCopyFilesToOutputDirectoryIfPossible=true \
    /p:CreateHardLinksForCopyLocalIfPossible=true \
    /p:CreateHardLinksForPublishFilesIfPossible=true \
    /p:ContinuousIntegrationBuild=true \
    "${RUNTIME_BUILD_PROPS[@]}" \
    /p:ClangToolExe="$CLANG_EXE" \
    /p:LlvmArToolExe="$LLVM_AR_EXE" \
    /p:EnableOSXCodeSign=false \
    "$IKVM_BUILD_PROJECT"
done

# The desktop target's libikvm (IKVM.Runtime's [DllImport("ikvm")]): a host that runs the same managed stack on the
# desktop, with the image as its java.home, loads it from beside its executable.
log "Building the $BUILD_RUNTIME libikvm ..."
dotnet msbuild /nr:false /restore \
    /p:Configuration="Release" \
    "/p:TargetIdentifiers=$BUILD_RUNTIME" \
    ${CLANG_COMPAT_FLAGS:+"/p:AdditionalCompileOptions=$CLANG_COMPAT_FLAGS"} \
    /p:ClangToolExe="$CLANG_EXE" \
    /p:LlvmArToolExe="$LLVM_AR_EXE" \
    src/libikvm/libikvm.clangproj

# ── Step 6: Package Managed Outputs ──────────────────────────────────────────

log "Packaging managed outputs ..."
mkdir -p "$OUT_BASE/managed"

copy_managed_outputs "$OUT_BASE/managed"
cp "$IKVM_ARTIFACTS_DIR/bin/libikvm/Release/$BUILD_RUNTIME/libikvm.so" "$OUT_BASE/managed/"

IKVM_TOOLS_DIST_DIR="${IKVM_TOOLS_DIST_DIR:-$(find_tools_dist_dir)}"
if [ -z "$IKVM_TOOLS_DIST_DIR" ] || [ ! -d "$IKVM_TOOLS_DIST_DIR" ]; then
    echo "ERROR: no IKVM tools found for $BUILD_RUNTIME" >&2
    echo "       present: $(ls -d "$IKVM_ARTIFACTS_DIR"/bin/ikvmc/Release/*/ 2>/dev/null | tr '\n' ' ')" >&2
    echo "       (override with IKVM_TOOLS_DIST_DIR=<path>)" >&2
    exit 1
fi
log "Using IKVM tools from ${IKVM_TOOLS_DIST_DIR#$IKVM_DIR/}"

rm -rf "$OUT_BASE/managed/ikvm-tools"
mkdir -p "$OUT_BASE/managed/ikvm-tools"
cp -r "$IKVM_TOOLS_DIST_DIR/." "$OUT_BASE/managed/ikvm-tools/"

log "Done! Managed outputs are in $OUT_BASE/managed/"
ls -lh "$OUT_BASE/managed/"

fi # end SKIP_MANAGED=false (Steps 3-6)

# Validate the image before spending time compiling natives for the bundle.
if [ "$SKIP_BUNDLE" = "false" ] && [ -f "$OUT_BASE/managed/IKVM.Runtime.dll" ]; then
    IMAGE_DIR="$(find_image_dir)"
    log "Using JRE image from ${IMAGE_DIR#"$IKVM_DIR"/}"
fi

if [ "$SKIP_NATIVE" = "true" ]; then
    log "Skipping WASM native build."
else
    # ── Step 7: Build WASM Native ─────────────────────────────────────────────

    # ── emsdk setup ───────────────────────────────────────────────────────────

    EMSDK_DIR="$WORKSPACE/.emsdk"

    if emcc --version 2>/dev/null | grep -q "$EMSDK_VERSION"; then
        log "emsdk $EMSDK_VERSION already active."
    else
        log "Setting up emsdk $EMSDK_VERSION in $EMSDK_DIR ..."
        if [ ! -d "$EMSDK_DIR/.git" ]; then
            git clone https://github.com/emscripten-core/emsdk.git "$EMSDK_DIR"
        fi
        "$EMSDK_DIR/emsdk" install "$EMSDK_VERSION"
        "$EMSDK_DIR/emsdk" activate "$EMSDK_VERSION"
    fi

    if [ -f "$EMSDK_DIR/emsdk_env.sh" ]; then
        # shellcheck source=/dev/null
        source "$EMSDK_DIR/emsdk_env.sh"
    fi

    require_cmd emcc
    require_cmd em++
    require_cmd emar

    if [ "$CLEAN_NATIVE" = "true" ]; then
        log "Cleaning native output directory ..."
        rm -rf "$OUT_BASE/native/"*
    fi

    mkdir -p "$OUT_BASE/native"

    NATIVE_JOBS="${NATIVE_JOBS:-$(nproc 2>/dev/null || echo 4)}"
    export NATIVE_JOBS
    log "Native compile parallelism: $NATIVE_JOBS job(s)"

    log "Building WASM native artifacts ..."
    bash "$WORKSPACE/build-ikvm-native.sh" "$IKVM_DIR" "$OUT_BASE"

    log "Done! WASM native artifacts are in $OUT_BASE/native/"
fi

# ── Step 8: Bundle Release Zip ──────────────────────────────────────────────

if [ "$SKIP_BUNDLE" = "true" ]; then
    log "Skipping bundle step."
elif [ ! -f "$OUT_BASE/managed/IKVM.Runtime.dll" ]; then
    log "Skipping bundle step: managed DLLs not present in ${OUT_BASE#$WORKSPACE/}/managed/ (run without --skip-managed to build them)."
else
    log "Bundling the release zip ..."

    mkdir -p "$OUT_BASE/release"
    rm -rf "$OUT_BASE/bundle-staging"
    mkdir -p "$OUT_BASE/bundle-staging/image"

    # Copy image files into staging area
    cp -r "$IMAGE_DIR/." "$OUT_BASE/bundle-staging/image/"

    # The wasm build links the native libraries in; the JDK still looks a library up by its file before it loads it,
    # and the image has only the desktop target's java.base ones. Empty files stand in for the rest.
    for lib in "${NATIVE_LIBS[@]}"; do
        case "$lib" in libjvm|libikvm|libfreetype) continue ;; esac
        [ -e "$OUT_BASE/bundle-staging/image/bin/$lib.so" ] || : > "$OUT_BASE/bundle-staging/image/bin/$lib.so"
    done

    IKVM_TOOLS_SRC="$OUT_BASE/managed/ikvm-tools"
    if [ ! -d "$IKVM_TOOLS_SRC" ]; then
        _tools_fallback="$(find_tools_dist_dir)"
        if [ -n "$_tools_fallback" ]; then
            log "ikvm-tools not found in ${OUT_BASE#$WORKSPACE/}/managed, using ${_tools_fallback#$IKVM_DIR/} fallback."
            IKVM_TOOLS_SRC="$_tools_fallback"
        fi
    fi
    if [ ! -d "$IKVM_TOOLS_SRC" ]; then
        echo "ERROR: ikvm-tools directory not found for bundling." >&2
        exit 1
    fi
    cp -r "$IKVM_TOOLS_SRC" "$OUT_BASE/bundle-staging/ikvm-tools"

    MANAGED_FILES=("$OUT_BASE/managed/IKVM."{Runtime,CoreLib,Java,ByteCode}.dll)
    # the desktop libikvm, when this managed build made one
    [ -f "$OUT_BASE/managed/libikvm.so" ] && MANAGED_FILES+=("$OUT_BASE/managed/libikvm.so")
    NATIVE_FILES=()
    for lib in "${NATIVE_LIBS[@]}"; do
        NATIVE_FILES+=("$OUT_BASE/native/$lib.a")
    done

    rm -f "$OUT_BASE/release/ikvm-wasm-bundle.zip"
    log "  Creating ikvm-wasm-bundle.zip ..."
    (
        cd "$OUT_BASE/bundle-staging"
        zip -j "$OUT_BASE/release/ikvm-wasm-bundle.zip" "${MANAGED_FILES[@]}" "${NATIVE_FILES[@]}"
        zip -r "$OUT_BASE/release/ikvm-wasm-bundle.zip" image
        zip -r "$OUT_BASE/release/ikvm-wasm-bundle.zip" ikvm-tools
    )

    rm -rf "$OUT_BASE/bundle-staging"

    log "Done! The release zip is in $OUT_BASE/release/"
    ls -lh "$OUT_BASE/release/"
fi
