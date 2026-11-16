import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.jvm")
}

val zstdVersion = providers.gradleProperty("zstdVersion").get()

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    // Each consumer supplies the build of zstd-jni that fits its platform.
    compileOnly("com.github.luben:zstd-jni:$zstdVersion")
}
