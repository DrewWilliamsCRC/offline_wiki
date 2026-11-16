import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.jvm")
    application
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
    implementation(project(":core"))
    implementation("com.github.luben:zstd-jni:$zstdVersion")
    implementation("it.unimi.dsi:fastutil:8.5.19") // sorting primitive arrays with a comparator
}

application {
    mainClass.set("wikireader.indexer.MainKt")
    applicationDefaultJvmArgs = listOf("-Xmx5g")
}
