#!/usr/bin/env bash
# build-ikvm-native.sh — Builds the fork's WASM native static libraries, from JDK 25's sources.
# Assumes emcc, em++, emar are already in PATH, and that the managed build ran: the JDK's make it drives generated the
# JNI headers under artifacts/jdk25/openjdk-build/support.
#
# Usage: build-ikvm-native.sh <ikvm-src-dir> <out-dir>
#   ikvm-src-dir   path to the fork's checkout
#   out-dir        output base directory; *.a files are written to <out-dir>/native/
#
# The JDK 9+ source layout lets one function build every library the way the JDK's make does (SetupJdkLibrary in
# make/common/JdkNativeCompilation.gmk): the sources under src/<module>/{linux,unix,share}/native/lib<name> and
# EXTRA_SRC, less EXCLUDES and EXCLUDE_FILES, with those directories, the module's generated JNI headers and
# EXTRA_HEADER_DIRS on the include path. Each definition below mirrors the library's make file
# (make/modules/<module>/Lib.gmk or lib/*.gmk); what differs for wasm is said where it does.
#
# All the libraries are static archives linked into one wasm module, which changes two things:
# - each library's JNI_OnLoad/JNI_OnUnload is renamed __lib<name>_JNI_OnLoad/_OnUnload, which gen-static-libs.py
#   exposes as that library's JNI_OnLoad (one global JNI_OnLoad per library would collide);
# - only the pthread variant is built (JDK 8's build had a single-threaded one as well).

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $(basename "$0") <ikvm-src-dir> <out-dir>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IKVM_SRC="$(cd "$1" && pwd)"
OUT_DIR="$2"

log() { echo "[build-ikvm-native] $*"; }

OJ_SRC="$IKVM_SRC/ext/openjdk/src"
SUPPORT="${IKVM_JDK25_SUPPORT_DIR:-$IKVM_SRC/artifacts/jdk25/openjdk-build/support}"
FREETYPE_DIR="$IKVM_SRC/ext/freetype"
NATIVE_OUT="$OUT_DIR/native"
TMP_DIR="$NATIVE_OUT/tmp"

if [ ! -d "$SUPPORT/headers/java.base" ]; then
    echo "ERROR: no JNI headers at $SUPPORT/headers; run the managed build first (build-ikvm-local.sh without --native-only)" >&2
    exit 1
fi

mkdir -p "$NATIVE_OUT" "$TMP_DIR"

# ── Parallel compile job pool ─────────────────────────────────────────────────
# Compiles run in the background, NATIVE_JOBS at a time; create_archive drains them.
NATIVE_JOBS="${NATIVE_JOBS:-$(nproc 2>/dev/null || echo 4)}"
if ! [[ "$NATIVE_JOBS" =~ ^[0-9]+$ ]] || [ "$NATIVE_JOBS" -lt 1 ]; then
    NATIVE_JOBS=1
fi
log "Compile parallelism: NATIVE_JOBS=$NATIVE_JOBS"

_jobs_running=0
_job_failed=0

_reap_one() {
    if wait -n 2>/dev/null; then :; else _job_failed=1; fi
    _jobs_running=$((_jobs_running - 1))
}

run_compile() {
    while [ "$_jobs_running" -ge "$NATIVE_JOBS" ]; do
        _reap_one
    done
    "$@" &
    _jobs_running=$((_jobs_running + 1))
}

barrier() {
    while [ "$_jobs_running" -gt 0 ]; do
        _reap_one
    done
    if [ "$_job_failed" -ne 0 ]; then
        echo "ERROR: a native compile job failed" >&2
        exit 1
    fi
}

create_archive() {
    barrier
    local archive="$1"
    shift
    rm -f "$archive"
    emar rcs "$archive" "$@"
}

# ── The version (VERSION_CFLAGS), from the fork's Directory.Build.props ──────

openjdk_prop() {
    sed -n "/<PropertyGroup Label=\"OpenJDK Info\">/,/<\/PropertyGroup>/s|.*<$1>\([^<]*\)</$1>.*|\1|p" "$IKVM_SRC/Directory.Build.props" | head -n 1
}

V_FEATURE="$(openjdk_prop OpenJdkFeatureVersion)"
V_INTERIM="$(openjdk_prop OpenJdkInterimVersion)"
V_UPDATE="$(openjdk_prop OpenJdkUpdateVersion)"
V_PATCH="$(openjdk_prop OpenJdkPatchVersion)"
V_BUILD="$(openjdk_prop OpenJdkBuildNumber)"
V_NUMBER="$V_FEATURE.$V_INTERIM.$V_UPDATE.$V_PATCH"
if [ -z "$V_FEATURE" ] || [ -z "$V_BUILD" ]; then
    echo "ERROR: could not read the JDK version from $IKVM_SRC/Directory.Build.props" >&2
    exit 1
fi
log "JDK version $V_NUMBER+$V_BUILD"

VERSION_CFLAGS=(
    "-DVERSION_FEATURE=$V_FEATURE" "-DVERSION_INTERIM=$V_INTERIM" "-DVERSION_UPDATE=$V_UPDATE"
    "-DVERSION_PATCH=$V_PATCH" -DVERSION_EXTRA1=0 -DVERSION_EXTRA2=0 -DVERSION_EXTRA3=0
    '-DVERSION_PRE=""' "-DVERSION_BUILD=$V_BUILD" '-DVERSION_OPT=""'
    "-DVERSION_NUMBER=\"$V_NUMBER\"" "-DVERSION_STRING=\"$V_NUMBER+$V_BUILD\""
    "-DVERSION_SHORT=\"$V_NUMBER\"" "-DVERSION_SPECIFICATION=\"$V_FEATURE\"" '-DVENDOR="IKVM"'
)

# ── CFLAGS_JDKLIB ─────────────────────────────────────────────────────────────
# The flags of every JDK library (targets/openjdk25.lib.props has the same for the native targets). The JNI headers
# are the JDK's: jni_md.h types jlong by _LP64, which wasm32 does not define. emscripten does not define __linux__,
# which the JDK's Linux code is conditional on; emscripten-stubs has the Linux headers emscripten lacks (linux/fs.h,
# sys/epoll.h, ...). The final wasm link uses -fwasm-exceptions, which makes setjmp/longjmp (libjavajpeg's and
# FreeType's error handling) wasm EH; every object is built that way so none emits the emscripten_longjmp shim.

COMMON_FLAGS=(
    -O2 -fPIC -pthread -fwasm-exceptions -fno-strict-aliasing
    -Wno-error -Wno-error=implicit-function-declaration -Wno-error=int-conversion
    -Wno-error=incompatible-function-pointer-types -Wno-deprecated-non-prototype
)
COMMON_DEFS=(
    -DNDEBUG -D_LITTLE_ENDIAN
    -DLINUX -D__linux__ -D_GNU_SOURCE -D_REENTRANT -D_FILE_OFFSET_BITS=64
    # IKVM's libjvm keeps the one-parameter JVM_LoadLibrary of earlier JDKs in the wasm build (src/libjvm/ikvm.h):
    # jvm.h's declaration and the JDK's callers drop the second argument
    '-DJVM_LoadLibrary(name,throwException)=JVM_LoadLibrary(name)'
)
COMMON_INCLUDES=(
    -I"$SUPPORT/modules_include/java.base"
    -I"$SUPPORT/modules_include/java.base/linux"
    -I"$OJ_SRC/hotspot/share/include"
    -I"$OJ_SRC/hotspot/os/posix/include"
    -I"$OJ_SRC/java.base/share/native/libjava"
    -I"$OJ_SRC/java.base/unix/native/libjava"
    -I"$SUPPORT/headers/java.base"
    -I"$SCRIPT_DIR/emscripten-stubs"
)
C_STD=(-std=c11)
CXX_STD=(-std=c++14 -fno-rtti -fno-exceptions -fno-threadsafe-statics)

# ── SetupJdkLibrary ───────────────────────────────────────────────────────────

# FindSrcDirsForComponent: the directories of a component of a module, the OS's first.
find_src_dirs() {
    local module="$1" component="$2" os
    for os in linux unix share; do
        if [ -d "$OJ_SRC/$module/$os/native/$component" ]; then
            echo "$OJ_SRC/$module/$os/native/$component"
        fi
    done
}

# ProcessSrcDir: "module:component", an absolute path, libjvm (HotSpot's include directories), or a component of
# the library's own module.
resolve_dirs() {
    local module="$1" spec="$2"
    case "$spec" in
        /*) echo "$spec" ;;
        libjvm|*:libjvm)
            echo "$OJ_SRC/hotspot/share/include"
            echo "$OJ_SRC/hotspot/os/posix/include"
            ;;
        *:*) find_src_dirs "${spec%%:*}" "${spec#*:}" ;;
        *) find_src_dirs "$module" "$spec" ;;
    esac
}

# The arguments of jdk_lib, as SetupJdkLibrary's; jdk_lib clears them.
reset_lib_args() {
    L_SRC=()            # replaces the default source directories
    L_EXTRA_SRC=()
    L_EXCLUDES=()       # directories, relative to a source directory
    L_EXCLUDE_FILES=()  # file names, or paths relative to a source directory
    L_HEADER_DIRS=()    # EXTRA_HEADER_DIRS
    L_JDK_LIBS=()       # the libraries whose source directories are on the include path
    L_CFLAGS=()         # C and C++
    L_CXXFLAGS=()       # C++ only
    L_EXTRA_FILES=()    # sources outside the source directories (EXTRA_FILES)
    declare -gA L_FILE_CFLAGS=()  # by file name, as <file>_CFLAGS
}
reset_lib_args

# jdk_lib <name> <module> [<archive name>]
jdk_lib() {
    local name="$1" module="$2" archive="${3:-lib$1}"
    # IKVM_NATIVE_ONLY=<archive>: that library alone (after libjvm), then stop
    if [ -n "${IKVM_NATIVE_ONLY:-}" ] && [ "$IKVM_NATIVE_ONLY" != "$archive" ]; then
        reset_lib_args
        return
    fi
    local -a src_dirs=() includes=() srcs=() objs=() lib_defs=()
    local d spec f rel base skip x obj
    local -a file_cflags=()
    local -A seen=()

    if [ "${#L_SRC[@]}" -gt 0 ]; then
        src_dirs=("${L_SRC[@]}")
    else
        mapfile -t src_dirs < <(find_src_dirs "$module" "lib$name")
    fi
    for spec in "${L_EXTRA_SRC[@]}"; do
        mapfile -t -O "${#src_dirs[@]}" src_dirs < <(resolve_dirs "$module" "$spec")
    done
    if [ "${#src_dirs[@]}" -eq 0 ]; then
        echo "ERROR: no source directories for lib$name in $module" >&2
        exit 1
    fi

    # sources in the order of their directories; the objects are named by file, so the first of a name wins
    for d in "${src_dirs[@]}"; do
        while IFS= read -r f; do
            rel="${f#"$d"/}"
            base="${f##*/}"
            skip=0
            for x in "${L_EXCLUDES[@]}"; do
                [[ "$rel" == "$x"/* ]] && skip=1
            done
            for x in "${L_EXCLUDE_FILES[@]}"; do
                [[ "$rel" == "$x" || "$rel" == */"$x" || "$base" == "$x" ]] && skip=1
            done
            [ "$skip" -eq 1 ] && continue
            [ -n "${seen[$base]+x}" ] && continue
            seen[$base]=1
            srcs+=("$f")
        done < <(find "$d" -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.cc' \) | LC_ALL=C sort)
    done

    srcs+=("${L_EXTRA_FILES[@]}")

    # the source directories, the module's JNI headers, EXTRA_HEADER_DIRS, then those of JDK_LIBS and jni.h's
    for d in "${src_dirs[@]}"; do
        includes+=("-I$d")
    done
    if [ -d "$SUPPORT/headers/$module" ]; then
        includes+=("-I$SUPPORT/headers/$module")
    fi
    for spec in "${L_HEADER_DIRS[@]}" "${L_JDK_LIBS[@]}" "$SUPPORT/modules_include/java.base" java.base:include; do
        while IFS= read -r d; do
            includes+=("-I$d")
        done < <(resolve_dirs "$module" "$spec")
    done

    lib_defs=("-DJNI_OnLoad=__lib${name}_JNI_OnLoad" "-DJNI_OnUnload=__lib${name}_JNI_OnUnload")

    log "Building $archive (${#srcs[@]} sources) ..."
    mkdir -p "$TMP_DIR/$archive"
    for f in "${srcs[@]}"; do
        base="${f##*/}"
        obj="$TMP_DIR/$archive/${base%.*}.o"
        read -r -a file_cflags <<< "${L_FILE_CFLAGS[$base]:-}"
        case "$f" in
            *.c)
                run_compile emcc "${COMMON_FLAGS[@]}" "${C_STD[@]}" "${COMMON_DEFS[@]}" "${lib_defs[@]}" \
                    "${L_CFLAGS[@]}" "${file_cflags[@]}" "${COMMON_INCLUDES[@]}" "${includes[@]}" -c "$f" -o "$obj"
                ;;
            *)
                run_compile em++ "${COMMON_FLAGS[@]}" "${CXX_STD[@]}" "${COMMON_DEFS[@]}" "${lib_defs[@]}" \
                    "${L_CFLAGS[@]}" "${L_CXXFLAGS[@]}" "${file_cflags[@]}" "${COMMON_INCLUDES[@]}" "${includes[@]}" \
                    -c "$f" -o "$obj"
                ;;
        esac
        objs+=("$obj")
    done
    create_archive "$NATIVE_OUT/$archive.a" "${objs[@]}"
    reset_lib_args
    [ "${IKVM_NATIVE_ONLY:-}" = "$archive" ] && exit 0
    return 0
}

# ── libjvm ────────────────────────────────────────────────────────────────────
# IKVM's (src/libjvm), against JDK 25's jni.h and jvm.h, as src/jdk25-native/libjvm.

LIBJVM_SRC="$IKVM_SRC/src/libjvm"
LIBJVM_FLAGS=(
    "${COMMON_FLAGS[@]}" -fdeclspec -Wno-dll-attribute-on-redeclaration "${COMMON_DEFS[@]}"
    "${COMMON_INCLUDES[@]}" -I"$LIBJVM_SRC"
)

log "Building libjvm ..."
mkdir -p "$TMP_DIR/libjvm"
LIBJVM_OBJS=()
for f in jni.c jni_vargs.c jvm_emscripten_dynlib.c jvm_native_bridge.c; do
    run_compile emcc "${LIBJVM_FLAGS[@]}" -std=c99 -c "$LIBJVM_SRC/$f" -o "$TMP_DIR/libjvm/${f%.c}.o"
    LIBJVM_OBJS+=("$TMP_DIR/libjvm/${f%.c}.o")
done
run_compile em++ "${LIBJVM_FLAGS[@]}" -std=c++11 -c "$LIBJVM_SRC/jvm.cpp" -o "$TMP_DIR/libjvm/jvm.o"
LIBJVM_OBJS+=("$TMP_DIR/libjvm/jvm.o")
create_archive "$NATIVE_OUT/libjvm.a" "${LIBJVM_OBJS[@]}"
# IKVM_NATIVE_ONLY=libjvm: just that (build-libjvm-only.sh); another library's name: libjvm and that one.
[ "${IKVM_NATIVE_ONLY:-}" = libjvm ] && exit 0

# ── libikvm ───────────────────────────────────────────────────────────────────
# Independent of the JDK. Globbed, as src/libikvm/libikvm.clangproj does.

if [ -z "${IKVM_NATIVE_ONLY:-}" ] || [ "$IKVM_NATIVE_ONLY" = libikvm ]; then
    log "Building libikvm ..."
    mkdir -p "$TMP_DIR/libikvm"
    LIBIKVM_OBJS=()
    for f in "$IKVM_SRC/src/libikvm"/*.c; do
        base="${f##*/}"
        run_compile emcc -O2 -fPIC -pthread -DLINUX -c "$f" -o "$TMP_DIR/libikvm/${base%.c}.o"
        LIBIKVM_OBJS+=("$TMP_DIR/libikvm/${base%.c}.o")
    done
    create_archive "$NATIVE_OUT/libikvm.a" "${LIBIKVM_OBJS[@]}"
    [ "${IKVM_NATIVE_ONLY:-}" = libikvm ] && exit 0
fi

# ── java.base ─────────────────────────────────────────────────────────────────

# libjava, named iava for IKVM, less the natives of the VM's interfaces, which the runtime implements (the
# LibJavaExclude list of src/jdk25-native/libiava/libiava.clangproj). os.arch stays amd64: LWJGL picks its natives
# by it.
L_SRC=()
mapfile -t L_SRC < <(find_src_dirs java.base libjava)
L_EXCLUDE_FILES=(
    Array.c BootLoader.c CDS.c Class.c ClassLoader.c ConstantPool.c Continuation.c ContinuationSupport.c
    Double.c Executable.c Field.c Finalizer.c Float.c ForeignLinkerSupport.c LambdaProxyClassArchive.c
    Module.c NativeAccessors.c NativeLibraries.c NullPointerException.c Object.c PhantomReference.c
    PreviewFeatures.c Reference.c Reflection.c Runtime.c Shutdown.c Signal.c StackFrameInfo.c
    StackStreamFactory.c StackTraceElement.c String.c System.c Thread.c ThreadSnapshot.c Throwable.c
    VirtualThread.c VM.c VMSupport.c
)
L_JDK_LIBS=(libjvm)
L_CFLAGS=("${VERSION_CFLAGS[@]}" '-DARCHPROPNAME="amd64"')
# emscripten has no sysinfo, which CgroupMetrics.c calls
L_EXTRA_FILES=("$SCRIPT_DIR/emscripten-stubs/sysinfo_stub.c")
jdk_lib iava java.base libiava

# libzip, with its bundled zlib
L_SRC=("$OJ_SRC/java.base/share/native/libzip")
L_JDK_LIBS=(libjava libjvm)
L_CFLAGS=(-I"$OJ_SRC/java.base/share/native/libzip/zlib" -DUSE_MMAP -UDEBUG)
jdk_lib zip java.base

# libnet and libnio
L_JDK_LIBS=(libjava libjvm)
# emscripten has no sockets or interface ioctls to enumerate network interfaces with; answer them from a fixed set
# (emscripten-stubs/ikvm_netif.h)
L_FILE_CFLAGS[NetworkInterface.c]="-include $SCRIPT_DIR/emscripten-stubs/ikvm_netif.h"
jdk_lib net java.base

L_HEADER_DIRS=(libnio/ch libnio/fs libjvm)
L_JDK_LIBS=(libjava libnet)
# sun.nio.fs compares errno with the Linux numbers its UnixConstants has. Convert both thrown exceptions
# (the forced include) and the status codes returned by stat0/access0 (the generated source patch).
L_FILE_CFLAGS[UnixNativeDispatcher.c]="-include $SCRIPT_DIR/emscripten-stubs/ikvm_linux_errno.h"
# WASMFS fails every byte-range lock, which FileChannel.tryLock then reports as held elsewhere (emscripten-stubs/ikvm_fcntl_lock.h)
L_FILE_CFLAGS[UnixFileDispatcherImpl.c]="-include $SCRIPT_DIR/emscripten-stubs/ikvm_fcntl_lock.h"
# emscripten has no socketpair, for the fd asynchronous closes dup2 over (emscripten-stubs/ikvm_socketpair.h)
L_FILE_CFLAGS[UnixDispatcher.c]="-include $SCRIPT_DIR/emscripten-stubs/ikvm_socketpair.h"
# Keep the OpenJDK checkout unchanged; compile the patched dispatcher in place of the original.
mkdir -p "$TMP_DIR/libnio"
NIO_DISPATCHER="$TMP_DIR/libnio/UnixNativeDispatcher.c"
patch --batch --silent --output="$NIO_DISPATCHER" \
    "$OJ_SRC/java.base/unix/native/libnio/fs/UnixNativeDispatcher.c" \
    "$SCRIPT_DIR/emscripten-stubs/UnixNativeDispatcher.patch"
L_EXCLUDE_FILES=(UnixNativeDispatcher.c)
# nor the extended attribute functions, which UnixNativeDispatcher.c calls
L_EXTRA_FILES=("$NIO_DISPATCHER" "$SCRIPT_DIR/emscripten-stubs/xattr_stub.c")
jdk_lib nio java.base

# ── java.prefs ────────────────────────────────────────────────────────────────

L_JDK_LIBS=(java.base:libjava java.base:libjvm)
jdk_lib prefs java.prefs

# ── java.management ───────────────────────────────────────────────────────────
# The JDK's libmanagement gets HotSpot's management interface (JVM_GetManagement) in its JNI_OnLoad, which IKVM's
# libjvm does not have; the runtime implements the natives of java.management. The library is IKVM's JNI_OnLoad,
# so that loading it succeeds.

log "Building libmanagement ..."
mkdir -p "$TMP_DIR/libmanagement"
run_compile emcc "${COMMON_FLAGS[@]}" "${C_STD[@]}" "${COMMON_DEFS[@]}" "${COMMON_INCLUDES[@]}" \
    -c "$IKVM_SRC/src/libmanagement/jni_onload.c" -o "$TMP_DIR/libmanagement/jni_onload.o"
create_archive "$NATIVE_OUT/libmanagement.a" "$TMP_DIR/libmanagement/jni_onload.o"

# jdk.management's libmanagement_ext likewise (src/jdk25-native/libmanagement_ext)
log "Building libmanagement_ext ..."
mkdir -p "$TMP_DIR/libmanagement_ext"
run_compile emcc "${COMMON_FLAGS[@]}" "${C_STD[@]}" "${COMMON_DEFS[@]}" "${COMMON_INCLUDES[@]}" \
    -DJNI_OnLoad=__libmanagement_ext_JNI_OnLoad \
    -c "$IKVM_SRC/src/jdk25-native/libmanagement_ext/jni_onload.c" -o "$TMP_DIR/libmanagement_ext/jni_onload.o"
create_archive "$NATIVE_OUT/libmanagement_ext.a" "$TMP_DIR/libmanagement_ext/jni_onload.o"

# ── java.desktop: what headless image I/O needs ───────────────────────────────
# libawt's JavaVM pointer, which its sibling libraries use, is the global "jvm", and so is LWJGL's: renamed in all of
# them.

DESKTOP_CFLAGS=(-Djvm=__libawt_jvm)

LIBAWT_DEFAULT_HEADER_DIRS=(
    common/awt/utility
    libawt/awt/image
    libawt/awt/image/cvutils
    libawt/java2d
    libawt/java2d/loops
    libawt/java2d/pipe
)

# libmlib_image. MLIB_OS64BIT is for 64-bit targets only, and wasm32 is not one.
L_EXTRA_SRC=(common/awt/medialib)
L_HEADER_DIRS=(java.base:libjava)
L_EXCLUDE_FILES=(mlib_c_ImageBlendTable.c)
L_CFLAGS=("${DESKTOP_CFLAGS[@]}" -D__USE_J2D_NAMES -D__MEDIALIB_OLD_NAMES -DMLIB_NO_LIBSUNMATH)
jdk_lib mlib_image java.desktop

# libawt. ENABLE_HEADLESS_ONLY, so HEADLESS. awt_LoadLibrary.c finds libawt_headless's symbols in the process when
# JVM_IsStaticallyLinked, which IKVM's libjvm answers true for emscripten. awt_Mlib.c is built as for the JDK's static
# build, which calls libmlib_image's functions directly instead of finding them with dlopen and dlsym.
L_EXTRA_SRC=(common/awt/debug "$OJ_SRC/java.desktop/unix/native/common/awt")
L_EXCLUDE_FILES=(awt_Font.c CUPSfuncs.c fontpath.c X11Color.c)
L_HEADER_DIRS=(
    "${LIBAWT_DEFAULT_HEADER_DIRS[@]}" "$SUPPORT/headers/java.base"
    libawt/awt/medialib libawt/java2d/d3d libawt/java2d/opengl libawt/java2d/windows libawt/windows
    common/awt/medialib libmlib_image include
)
L_JDK_LIBS=(java.base:libjava java.base:libjvm)
L_CFLAGS=("${DESKTOP_CFLAGS[@]}" -D__MEDIALIB_OLD_NAMES -D__USE_J2D_NAMES -DMLIB_NO_LIBSUNMATH -DHEADLESS)
L_FILE_CFLAGS[awt_Mlib.c]="-DSTATIC_BUILD"
jdk_lib awt java.desktop

# libawt_headless. Static: systemScale.o is libawt's (STATIC_LIB_EXCLUDE_OBJS). For wasm, also without
# CUPSfuncs.c and fontpath.c, which need the CUPS and fontconfig headers.
L_EXTRA_SRC=(common/font common/java2d "$OJ_SRC/java.desktop/unix/native/common/awt")
L_EXCLUDES=(medialib opengl)
L_EXCLUDE_FILES=(
    GLXGraphicsConfig.c GLXSurfaceData.c X11PMBlitLoops.c X11Renderer.c X11SurfaceData.c
    systemScale.c CUPSfuncs.c fontpath.c
)
L_HEADER_DIRS=("${LIBAWT_DEFAULT_HEADER_DIRS[@]}" common/awt/debug common/font java.base:libjvm)
L_JDK_LIBS=(libawt java.base:libjava)
L_CFLAGS=("${DESKTOP_CFLAGS[@]}" -DHEADLESS=true)
jdk_lib awt_headless java.desktop

# liblcms, bundled
L_HEADER_DIRS=(common/awt/debug libawt/java2d java.base:libjvm)
L_JDK_LIBS=(libawt java.base:libjava)
L_CFLAGS=("${DESKTOP_CFLAGS[@]}" -DCMS_DONT_USE_FAST_FLOOR -DCMS_NO_HALF_SUPPORT)
jdk_lib lcms java.desktop

# libjavajpeg, with its bundled libjpeg
L_JDK_LIBS=(java.base:libjava)
L_CFLAGS=("${DESKTOP_CFLAGS[@]}")
jdk_lib javajpeg java.desktop

# libfontmanager, with its bundled HarfBuzz, against the FreeType below
L_EXTRA_SRC=(libharfbuzz)
L_EXCLUDE_FILES=(
    gsubgpos-context.cc hb-ft.cc hb-style.cc hb-subset-cff-common.cc hb-subset-cff1.cc hb-subset-cff2.cc
    hb-subset-input.cc hb-subset-instancer-solver.cc hb-subset-plan.cc hb-subset.cc
    fontpath.c lcdglyph.c AccelGlyphCache.c
)
L_HEADER_DIRS=(
    common/awt common/awt/utility common/font libawt/java2d libawt/java2d/pipe libawt/java2d/loops
    "$FREETYPE_DIR/include"
)
L_JDK_LIBS=(libawt java.base:libjava java.base:libjvm)
L_CFLAGS=(
    "${DESKTOP_CFLAGS[@]}"
    -DGETPAGESIZE -DHAVE_MPROTECT -DHAVE_PTHREAD -DHAVE_SYSCONF -DHAVE_SYS_MMAN_H -DHAVE_UNISTD_H
    -DHB_NO_PRAGMA_GCC_DIAGNOSTIC -DHAVE_INTEL_ATOMIC_PRIMITIVES -DHB_NO_VISIBILITY
    -DLE_STANDALONE -DHEADLESS
)
jdk_lib fontmanager java.desktop

# ── libfreetype ───────────────────────────────────────────────────────────────
# ext/freetype (LWJGL's FreeType binding links the same archive).
# The file list is src/libfreetype/libfreetype.clangproj's.

LIBFT_SRCS=(
    src/autofit/autofit.c src/base/ftbase.c src/base/ftbbox.c src/base/ftbdf.c src/base/ftbitmap.c
    src/base/ftcid.c src/base/ftdebug.c src/base/ftfstype.c src/base/ftgasp.c src/base/ftglyph.c
    src/base/ftgxval.c src/base/ftinit.c src/base/ftmm.c src/base/ftotval.c src/base/ftpatent.c
    src/base/ftpfr.c src/base/ftstroke.c src/base/ftsynth.c src/base/fttype1.c src/base/ftwinfnt.c
    src/bdf/bdf.c src/cache/ftcache.c src/cff/cff.c src/cid/type1cid.c src/dlg/dlgwrap.c
    src/gzip/ftgzip.c src/lzw/ftlzw.c src/pcf/pcf.c src/pfr/pfr.c src/psaux/psaux.c
    src/pshinter/pshinter.c src/psnames/psmodule.c src/raster/raster.c src/sfnt/sfnt.c
    src/smooth/smooth.c src/sdf/sdf.c src/svg/svg.c src/truetype/truetype.c src/type1/type1.c
    src/type42/type42.c src/winfonts/winfnt.c builds/unix/ftsystem.c
)

log "Building libfreetype ..."
mkdir -p "$TMP_DIR/libfreetype"
LIBFT_OBJS=()
for rel in "${LIBFT_SRCS[@]}"; do
    base="${rel##*/}"
    run_compile emcc -O2 -fPIC -pthread -fwasm-exceptions -Wno-error -std=c99 \
        -DFT2_BUILD_LIBRARY -DHAVE_UNISTD_H -DHAVE_FCNTL_H -I"$FREETYPE_DIR/include" \
        -c "$FREETYPE_DIR/$rel" -o "$TMP_DIR/libfreetype/${base%.c}.o"
    LIBFT_OBJS+=("$TMP_DIR/libfreetype/${base%.c}.o")
done
create_archive "$NATIVE_OUT/libfreetype.a" "${LIBFT_OBJS[@]}"

# ── Collisions ────────────────────────────────────────────────────────────────
# gen-static-libs.py references every global the archives define, so all of their objects end up in the one wasm
# module: a name two archives define is a link error there. Fail here instead.

NM="${NM:-$(command -v llvm-nm || true)}"
if [ -n "$NM" ]; then
    dups="$(for a in "$NATIVE_OUT"/lib*.a; do
        "$NM" --defined-only -g "$a" 2>/dev/null | awk -v a="${a##*/}" 'NF == 3 && $2 != "W" && $2 != "V" { print $3 "\t" a }'
    done | LC_ALL=C sort -u | awk -F'\t' '{ n[$1]++; l[$1] = l[$1] " " $2 } END { for (s in n) if (n[s] > 1) print s ":" l[s] }')"
    if [ -n "$dups" ]; then
        echo "ERROR: symbols defined by more than one archive:" >&2
        echo "$dups" | sort >&2
        exit 1
    fi
fi

log "Done! Artifacts written to $NATIVE_OUT/"
ls -lh "$NATIVE_OUT"/lib*.a
