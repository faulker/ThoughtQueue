plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

/** Reads a Gradle property first, then the environment, so CI and local builds both work. */
fun setting(name: String): String? =
    (project.findProperty(name) as String?)?.takeIf { it.isNotBlank() }
        ?: System.getenv(name)?.takeIf { it.isNotBlank() }

val releaseKeystorePath = setting("TQ_ANDROID_KEYSTORE_PATH")
val releaseKeystorePassword = setting("TQ_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = setting("TQ_ANDROID_KEY_ALIAS")
val releaseKeyPassword = setting("TQ_ANDROID_KEY_PASSWORD")
// Without all four values the release build is left unsigned instead of failing.
val canSignRelease = listOf(
    releaseKeystorePath, releaseKeystorePassword, releaseKeyAlias, releaseKeyPassword,
).all { it != null }

android {
    namespace = "com.thoughtqueue.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.thoughtqueue.app"
        minSdk = 26
        targetSdk = 35
        versionCode = (setting("versionCode") ?: setting("VERSION_CODE"))?.toInt() ?: 1
        versionName = setting("versionName") ?: setting("VERSION_NAME") ?: "0.1.0"
    }

    signingConfigs {
        if (canSignRelease) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Optional, lets a minified build install beside the debug app: -PappIdSuffix=.rel
            setting("appIdSuffix")?.let { applicationIdSuffix = it }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (canSignRelease) signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.all { test ->
            // The opt-in S3 integration test reads these; forward them from the Gradle environment.
            listOf(
                "TQ_S3_ENDPOINT", "TQ_S3_BUCKET", "TQ_S3_ACCESS_KEY", "TQ_S3_SECRET_KEY",
                "TQ_S3_REGION", "TQ_S3_PATH_STYLE", "TQ_S3_PAGINATION",
            ).forEach { name -> System.getenv(name)?.let { test.environment(name, it) } }
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.text)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.security.crypto)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
