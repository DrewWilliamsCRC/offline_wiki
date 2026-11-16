plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val zstdVersion: String by project

android {
    namespace = "dev.offlinewiki.reader"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.offlinewiki.reader"
        minSdk = 28
        targetSdk = 34
        versionCode = 2
        versionName = "0.2"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Signed with this Mac's Android debug key (~/.android/debug.keystore) so the APK can be
            // sideloaded and later updated in place. A different key would force an uninstall first.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    lint { checkReleaseBuilds = false }
}

dependencies {
    implementation(project(":core"))
    implementation("com.github.luben:zstd-jni:$zstdVersion@aar")
}
