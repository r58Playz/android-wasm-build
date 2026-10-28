plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "androidx.compose.material.catalog"
    compileSdk { version = release(37) { minorApiLevel = 1 } }
    defaultConfig {
        applicationId = "androidx.compose.material.catalog"
        minSdk = 24
        targetSdk = 37
        versionCode = 1
        versionName = "wasm-target"
    }
    buildTypes {
        release {
            // R8 on, as an app ships; build.sh keeps mapping.txt next to the APK.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation(project(":catalog"))
    implementation("androidx.activity:activity-compose:1.14.0-SNAPSHOT")
    implementation("androidx.compose.material3:material3:1.6.0-SNAPSHOT")
    implementation("androidx.datastore:datastore-preferences:1.3.0-SNAPSHOT")
}
