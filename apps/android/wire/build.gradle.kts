// The Keeper chat wire types. src/main/kotlin/masc/wire/generated is written
// by tools/atd-native-gen from lib/keeper_chat_wire/keeper_chat_wire.atd;
// `dune build @check` fails when it drifts. Tests decode the server's
// fixture in apps/fixtures/keeper_chat.

plugins {
    `java-library`
    kotlin("jvm") version "2.4.21"
    kotlin("plugin.serialization") version "2.4.21"
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        allWarningsAsErrors = true
    }
}

dependencies {
    // Public: the generated types expose JsonElement.
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.13.0")
    testImplementation(kotlin("test"))
}

val fixtures = layout.projectDirectory.dir("../../fixtures/keeper_chat")

tasks.test {
    useJUnitPlatform()
    inputs.dir(fixtures)
    systemProperty("masc.fixtures", fixtures.asFile.absolutePath)
}
