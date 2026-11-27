import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The Android Gradle Plugin compiles Kotlin itself since version 9, so there is no separate Kotlin
// plugin here. The Kotlin version comes from org.jetbrains.kotlin.jvm in the root build file.
plugins {
    id("com.android.application")
}

val zstdVersion = providers.gradleProperty("zstdVersion").get()

android {
    namespace = "dev.offlinewiki.reader"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.offlinewiki.reader"
        minSdk = 28
        targetSdk = 34
        versionCode = 9
        versionName = "0.9"
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
    lint { checkReleaseBuilds = false }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":core"))
    implementation("com.github.luben:zstd-jni:$zstdVersion@aar")
}
