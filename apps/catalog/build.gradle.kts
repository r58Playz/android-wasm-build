// The snapshot AARs declare minAndroidGradlePluginVersion=9.1.0 and minCompileSdk=37 (minor 1).
// AGP 9 has built-in Kotlin; only the Compose compiler plugin is applied explicitly.
plugins {
    id("com.android.application") version "9.3.1" apply false
    id("com.android.library") version "9.3.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20" apply false
}
