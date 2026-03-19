open Alcotest
open Masc_mcp

let test_parse_text_tool_calls_single () =
  let content =
    {|mcp__masc__masc_team_session_step(session_id="ts-123", turn_kind="note", message="[local64-smoke-01] manager decide online for hybrid smoke")|}
  in
  match Local_agent_eio.parse_text_tool_calls content with
  | [ call ] ->
      check string "tool name" "masc_team_session_step" call.Cascade.call_name;
      let json = Yojson.Safe.from_string call.call_arguments in
      check string "session id" "ts-123"
        Yojson.Safe.Util.(json |> member "session_id" |> to_string);
      check string "turn kind" "note"
        Yojson.Safe.Util.(json |> member "turn_kind" |> to_string);
      check string "message"
        "[local64-smoke-01] manager decide online for hybrid smoke"
        Yojson.Safe.Util.(json |> member "message" |> to_string)
  | _ -> fail "expected exactly one parsed tool call"

let test_parse_text_tool_calls_multiple () =
  let content =
    {|
<think>
done
</think>
mcp__masc__masc_heartbeat()
mcp__masc__masc_team_session_step(session_id="ts-123", turn_kind="note", message="[local64-smoke-02] metacog verify online for hybrid smoke")
done:local64-smoke-02
|}
  in
  match Local_agent_eio.parse_text_tool_calls content with
  | [ first; second ] ->
      check string "first tool" "masc_heartbeat" first.Cascade.call_name;
      check string "heartbeat args" "{}" first.call_arguments;
      check string "second tool" "masc_team_session_step"
        second.Cascade.call_name
  | _ -> fail "expected two parsed text tool calls"

let () =
  run "Local_agent_eio"
    [
      ( "parser",
        [
          test_case "parse text tool calls single" `Quick
            test_parse_text_tool_calls_single;
          test_case "parse text tool calls multiple" `Quick
            test_parse_text_tool_calls_multiple;
        ] );
    ]
