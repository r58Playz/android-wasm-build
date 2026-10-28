// M3-only wrapper around the androidx Material 3 Catalog.
// The catalog library sources come from the sparse androidx checkout build.sh makes in androidx/;
// material3, its samples and the adaptive samples come prebuilt from one pinned androidx snapshot build.
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // androidx-main snapshot build 16733152 (2026-10-27 04:47 UTC). Keep the Gradle cache after the
        // first build: androidx.dev snapshot builds are not guaranteed to stay up.
        maven("https://androidx.dev/snapshots/builds/16733152/artifacts/repository")
    }
}
rootProject.name = "M3Catalog"
include(":app", ":catalog")
