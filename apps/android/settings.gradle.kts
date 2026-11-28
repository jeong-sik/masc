// Android clients for the MASC Keeper chat (RFC-native-keeper-chat-clients).
// Build with a local Gradle 9.x: `gradle :wire:test` from apps/android.
// The wrapper jar is not committed (no binaries in the repository).

pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

rootProject.name = "masc-android"

include(":wire")
