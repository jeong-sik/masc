// The generated types decode what the server writes: every frame in
// apps/fixtures/keeper_chat/agui_frames.json (the server encoder's output),
// plus the open and closed cases the fixture cannot show.

package masc.wire

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import masc.wire.generated.CustomName
import masc.wire.generated.Frame
import masc.wire.generated.FrameDeserializer
import masc.wire.generated.Role
import masc.wire.generated.WireJson

private class FixtureCase(val name: String, val raw: JsonElement) {
    val frame: Frame = WireJson.decodeFromJsonElement(FrameDeserializer, raw)
}

private fun fixture(): List<FixtureCase> {
    val dir = System.getProperty("masc.fixtures") ?: fail("masc.fixtures is not set")
    val text = File(dir, "agui_frames.json").readText()
    return WireJson.parseToJsonElement(text).jsonArray.map { item ->
        val obj = item.jsonObject
        val name = obj["case"]?.jsonPrimitive?.content ?: fail("a fixture case has no name")
        FixtureCase(name, obj["frame"] ?: fail("$name has no frame"))
    }
}

/** The wire name of a decoded kind; null for an unrecognized one. */
private fun kind(frame: Frame): String? = when (frame) {
    is Frame.RunStarted -> "RUN_STARTED"
    is Frame.RunFinished -> "RUN_FINISHED"
    is Frame.RunError -> "RUN_ERROR"
    is Frame.TextMessageStart -> "TEXT_MESSAGE_START"
    is Frame.TextMessageContent -> "TEXT_MESSAGE_CONTENT"
    is Frame.TextMessageEnd -> "TEXT_MESSAGE_END"
    is Frame.ToolCallStart -> "TOOL_CALL_START"
    is Frame.ToolCallArgs -> "TOOL_CALL_ARGS"
    is Frame.ToolCallEnd -> "TOOL_CALL_END"
    is Frame.Custom -> "CUSTOM"
    is Frame.Unrecognized -> null
}

private fun List<FixtureCase>.frame(name: String): Frame =
    firstOrNull { it.name == name }?.frame ?: fail("no fixture case $name")

private fun frame(json: String): Frame = WireJson.decodeFromString(FrameDeserializer, json)

class FrameDecodeTest {
    @Test
    fun everyServerFrameDecodesAsItsOwnKind() {
        val cases = fixture()
        assertTrue(cases.isNotEmpty())
        for (item in cases) {
            val type = (item.raw as? JsonObject)?.get("type")?.jsonPrimitive?.content
            assertNotNull(type, "${item.name}: fixture frame has no type")
            assertEquals(type, kind(item.frame), item.name)
            val custom = item.frame as? Frame.Custom ?: continue
            val name = custom.value.name
            if (name is CustomName.Unrecognized) {
                fail("${item.name}: CUSTOM name ${name.wireName} is not in the generated type")
            }
        }
    }

    @Test
    fun fieldsCarryTheirWireValues() {
        val cases = fixture()

        val bare = assertIs<Frame.RunError>(cases.frame("run_error without run_id or code")).value
        assertNull(bare.runId)
        assertNull(bare.code)
        assertTrue(bare.message.isNotEmpty())

        val whole = assertIs<Frame.RunFinished>(cases.frame("run_finished at a whole-second timestamp")).value
        assertEquals(13.0, whole.timestamp)

        val start = assertIs<Frame.TextMessageStart>(cases.frame("text_message_start")).value
        assertEquals(Role.Assistant, start.role)

        val observed =
            assertIs<Frame.TextMessageContent>(cases.frame("text_message_content, response observed")).value
        assertNotNull(observed.textResponse)
        assertNull(observed.textStreamScope)

        val snapshot = assertIs<Frame.ToolCallArgs>(cases.frame("tool_call_args snapshot")).value
        assertNotNull(snapshot.snapshot)
        assertNull(snapshot.delta)

        val connected = assertIs<Frame.Custom>(cases.frame("custom with run_id and null value")).value
        assertEquals(CustomName.KeeperConnected, connected.name)
        assertEquals(JsonNull, connected.value)
    }

    @Test
    fun anUnknownKindKeepsItsNameAndFrame() {
        val json = """{"type":"FUTURE_KIND","threadId":"t","timestamp":1}"""
        assertEquals(Frame.Unrecognized("FUTURE_KIND", WireJson.parseToJsonElement(json)), frame(json))
    }

    @Test
    fun anUnknownCustomNameKeepsTheName() {
        val custom = assertIs<Frame.Custom>(
            frame("""{"type":"CUSTOM","threadId":"t","timestamp":1,"name":"KEEPER_FUTURE","value":{}}"""),
        ).value
        assertEquals(CustomName.Unrecognized("KEEPER_FUTURE"), custom.name)
    }

    @Test
    fun aFieldANewerServerAddsIsIgnored() {
        val finished = assertIs<Frame.RunFinished>(
            frame("""{"type":"RUN_FINISHED","threadId":"t","runId":"r","timestamp":2,"futureField":[1]}"""),
        ).value
        assertEquals("r", finished.runId)
    }

    @Test
    fun closedTypesRefuseWhatTheyDoNotKnow() {
        assertFailsWith<SerializationException> { WireJson.decodeFromString(Role.serializer(), "\"moderator\"") }
        assertFailsWith<SerializationException> { frame("""{"type":"RUN_STARTED","threadId":"t","timestamp":1}""") }
        assertFailsWith<SerializationException> { frame("""{"threadId":"t","timestamp":1}""") }
        assertFailsWith<SerializationException> { frame("""{"type":7,"threadId":"t","timestamp":1}""") }
    }

    @Test
    fun anOpenNameWritesBackAsItWasRead() {
        val json = JsonPrimitive("KEEPER_FUTURE")
        val name = WireJson.decodeFromJsonElement(CustomName.serializer(), json)
        assertEquals(json, WireJson.encodeToJsonElement(CustomName.serializer(), name))
    }
}
