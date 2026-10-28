# android-wasm-build

The prebuilt inputs of the Android runner ([android-wasm](https://github.com/r58playz/android-wasm)), built by
`.github/workflows/android-wasm-build.yml` on every push to `main` and published as one release (a uuid tag) that the
runner's Makefile pins:

| Asset | Built by | What |
|---|---|---|
| `ikvm-wasm-bundle.zip` | `tools/ikvm/build-ikvm-local.sh` | IKVM from the fork's `android` branch (r58playz/ikvm): the runtime, ikvmc, JDK 25's class library and image, the WASM native libraries (IKVM's `libjvm` and `libikvm`, and the JDK's) via Emscripten, and the desktop `libikvm.so` (linux-x64) |
| `wink-mt.zip` | `tools/wink/build-wink.sh` | mesa-wink (Mesa's OpenGL on WebGPU) at its pinned commit, the threaded variant: archives, ordered JS libraries, headers, `manifest.json`, `wink.targets` |
| `catalog-release.apk`, `catalog-release-mapping.txt` | `apps/catalog/build.sh` | The androidx Material 3 Catalog, an R8 release build, from a pinned androidx-main commit and androidx.dev snapshot build |

Each script also runs locally; the runner takes a local build when it is copied over the downloaded file in its
`statics/`.

* `tools/ikvm/build-ikvm-local.sh` clones the fork into `tools/ikvm/ikvm` (or builds `$IKVM_DIR`) and writes
  `tools/ikvm/out/release/ikvm-wasm-bundle.zip`. It needs .NET 10, a JDK 25, mono, clang/llvm, emsdk 3.1.56 and the
  JDK's Linux build dependencies (see the workflow). `build-runtime-only.sh` and `build-importer-only.sh` rebuild
  IKVM.Runtime or ikvmc's compiler alone and patch them into an existing bundle.
* `tools/wink/build-wink.sh` clones mesa-wink into `tools/wink/mesa-wink` (or builds `$MESA_WINK_DIR`) and writes
  `tools/wink/out/wink-mt.zip`. It needs git, curl, cmake, ninja, bison, flex and Python 3.10 with venv; it caches
  Dawn/Tint in `~/.cache/mesa-wink`.
* `apps/catalog/build.sh` fetches the catalog's sources (a sparse androidx checkout in `apps/catalog/androidx`) and
  writes `apps/catalog/out/`. It needs JDK 21 and an Android SDK with `platforms;android-37.1`. The snapshot build it
  depends on is not guaranteed to stay up on androidx.dev; the release asset is the durable copy.
