plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Sources and res are the unmodified androidx checkout (build.sh):
// compose/material3/material3/integration-tests/material3-catalog
val catalogSrc = file("../androidx/compose/material3/material3/integration-tests/material3-catalog/src/main")

android {
    namespace = "androidx.compose.material3.catalog.library"
    compileSdk { version = release(37) { minorApiLevel = 1 } }
    defaultConfig { minSdk = 24 }
    sourceSets {
        getByName("main") {
            java.srcDir(catalogSrc.resolve("java"))
            kotlin.srcDir(catalogSrc.resolve("java"))
            res.srcDir(catalogSrc.resolve("res"))
        }
    }
}

dependencies {
    // Same set as material3-catalog/build.gradle, with project() deps mapped to the snapshot build.
    implementation("androidx.core:core:1.12.0")
    implementation("androidx.compose.material3:material3:1.6.0-SNAPSHOT")
    implementation("androidx.compose.material3:material3-samples:1.6.0-SNAPSHOT")
    implementation("androidx.compose.material3.adaptive:adaptive-samples:1.4.0-SNAPSHOT")
    implementation("androidx.compose.material3:material3-adaptive-navigation-suite-samples:1.6.0-SNAPSHOT")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("androidx.datastore:datastore-preferences:1.3.0-SNAPSHOT")
    implementation("androidx.navigation:navigation-compose:2.11.0-SNAPSHOT")
}
