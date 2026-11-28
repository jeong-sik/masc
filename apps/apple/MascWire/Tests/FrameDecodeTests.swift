// The generated types decode what the server writes: every frame in
// apps/fixtures/keeper_chat/agui_frames.json (the server encoder's output),
// plus the open and closed cases the fixture cannot show.

import Foundation
import Testing
@testable import MascWire

private let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // MascWire
    .deletingLastPathComponent()  // apple
    .deletingLastPathComponent()  // apps
    .appendingPathComponent("fixtures/keeper_chat/agui_frames.json")

private struct FixtureCase: Decodable {
    let name: String
    let frame: Frame
    let raw: JSONValue

    private enum CodingKeys: String, CodingKey {
        case name = "case"
        case frame
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        frame = try container.decode(Frame.self, forKey: .frame)
        raw = try container.decode(JSONValue.self, forKey: .frame)
    }
}

private func fixture() throws -> [FixtureCase] {
    try JSONDecoder().decode([FixtureCase].self, from: Data(contentsOf: fixtureURL))
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// The wire name of a decoded kind; nil for an unrecognized one.
private func kind(_ frame: Frame) -> String? {
    switch frame {
    case .runStarted: "RUN_STARTED"
    case .runFinished: "RUN_FINISHED"
    case .runError: "RUN_ERROR"
    case .textMessageStart: "TEXT_MESSAGE_START"
    case .textMessageContent: "TEXT_MESSAGE_CONTENT"
    case .textMessageEnd: "TEXT_MESSAGE_END"
    case .toolCallStart: "TOOL_CALL_START"
    case .toolCallArgs: "TOOL_CALL_ARGS"
    case .toolCallEnd: "TOOL_CALL_END"
    case .custom: "CUSTOM"
    case .unrecognized: nil
    }
}

private func frame(_ cases: [FixtureCase], _ name: String) throws -> Frame {
    try #require(cases.first { $0.name == name }).frame
}

@Test func everyServerFrameDecodesAsItsOwnKind() throws {
    let cases = try fixture()
    #expect(!cases.isEmpty)
    for item in cases {
        guard case .object(let object) = item.raw, case .string(let type)? = object["type"] else {
            Issue.record("\(item.name): fixture frame has no type")
            continue
        }
        #expect(kind(item.frame) == type, "\(item.name)")
        if case .custom(let custom) = item.frame, case .unrecognized(let name) = custom.name {
            Issue.record("\(item.name): CUSTOM name \(name) is not in the generated enum")
        }
    }
}

@Test func fieldsCarryTheirWireValues() throws {
    let cases = try fixture()

    guard case .runError(let bare) = try frame(cases, "run_error without run_id or code") else {
        Issue.record("not RUN_ERROR"); return
    }
    #expect(bare.runId == nil)
    #expect(bare.code == nil)
    #expect(!bare.message.isEmpty)

    guard case .runFinished(let whole) = try frame(cases, "run_finished at a whole-second timestamp") else {
        Issue.record("not RUN_FINISHED"); return
    }
    #expect(whole.timestamp == 13)

    guard case .textMessageStart(let start) = try frame(cases, "text_message_start") else {
        Issue.record("not TEXT_MESSAGE_START"); return
    }
    #expect(start.role == .assistant)

    guard case .textMessageContent(let observed) = try frame(cases, "text_message_content, response observed")
    else { Issue.record("not TEXT_MESSAGE_CONTENT"); return }
    #expect(observed.textResponse != nil)
    #expect(observed.textStreamScope == nil)

    guard case .toolCallArgs(let snapshot) = try frame(cases, "tool_call_args snapshot") else {
        Issue.record("not TOOL_CALL_ARGS"); return
    }
    #expect(snapshot.snapshot != nil)
    #expect(snapshot.delta == nil)

    guard case .custom(let connected) = try frame(cases, "custom with run_id and null value") else {
        Issue.record("not CUSTOM"); return
    }
    #expect(connected.name == .keeperConnected)
    #expect(connected.value == .null)
}

@Test func anUnknownKindKeepsItsNameAndFrame() throws {
    let frame = try decode(Frame.self, #"{"type":"FUTURE_KIND","threadId":"t","timestamp":1}"#)
    #expect(frame == .unrecognized(
        name: "FUTURE_KIND",
        raw: .object(["type": .string("FUTURE_KIND"), "threadId": .string("t"), "timestamp": .number(1)])))
}

@Test func anUnknownCustomNameKeepsTheName() throws {
    let frame = try decode(
        Frame.self, #"{"type":"CUSTOM","threadId":"t","timestamp":1,"name":"KEEPER_FUTURE","value":{}}"#)
    guard case .custom(let custom) = frame else { Issue.record("not CUSTOM"); return }
    #expect(custom.name == .unrecognized("KEEPER_FUTURE"))
}

@Test func closedTypesRefuseWhatTheyDoNotKnow() {
    #expect(throws: DecodingError.self) {
        try decode(Role.self, #""moderator""#)
    }
    #expect(throws: DecodingError.self) {
        try decode(Frame.self, #"{"type":"RUN_STARTED","threadId":"t","timestamp":1}"#)
    }
}

@Test func jsonValueKeepsEachKind() throws {
    let value = try decode(JSONValue.self, #"[1, true, 1.5, "s", null, {"a": []}]"#)
    #expect(value == .array([.number(1), .bool(true), .number(1.5), .string("s"), .null, .object(["a": .array([])])]))
}
