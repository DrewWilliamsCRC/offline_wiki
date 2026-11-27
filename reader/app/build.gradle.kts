import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

// The Android Gradle Plugin compiles Kotlin itself since version 9, so there is no separate Kotlin
// plugin here. The Kotlin version comes from org.jetbrains.kotlin.jvm in the root build file.
plugins {
    id("com.android.application")
}

val zstdVersion = providers.gradleProperty("zstdVersion").get()

// Google Play takes builds signed with an upload key, kept outside the repository with its password:
// ~/.android/wiki-reader-upload.properties (storeFile, storePassword, keyAlias, keyPassword), or the
// file the Gradle property wikiReaderUploadKey names. Without it, the "play" build is left unsigned.
val uploadKey = file(
    providers.gradleProperty("wikiReaderUploadKey").getOrElse(System.getProperty("user.home") + "/.android/wiki-reader-upload.properties"),
)

android {
    namespace = "dev.offlinewiki.reader"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.offlinewiki.reader"
        minSdk = 28
        targetSdk = 36
        versionCode = 10
        versionName = "1.0"
    }

    signingConfigs {
        if (uploadKey.isFile) create("upload") {
            val key = Properties().apply { uploadKey.inputStream().use { load(it) } }
            storeFile = file(key.getProperty("storeFile"))
            storePassword = key.getProperty("storePassword")
            keyAlias = key.getProperty("keyAlias")
            keyPassword = key.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Signed with this Mac's Android debug key (~/.android/debug.keystore) so the APK can be
            // sideloaded and later updated in place. A different key would force an uninstall first.
            signingConfig = signingConfigs.getByName("debug")
        }
        // For Google Play: ./gradlew :app:bundlePlay, which reader/scripts/play-upload.sh runs. The
        // same app as release, signed with the upload key. Play signs what it installs with its
        // own key, so a copy from Play and a sideloaded one cannot update each other.
        create("play") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.findByName("upload")
            matchingFallbacks += "release"
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
