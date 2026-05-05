(** Tests for [Cascade_attempt_liveness_oas_adapter] (RFC-0022 PR-3/4). *)

open Masc_mcp
module A = Cascade_attempt_liveness_oas_adapter
module SC = Cascade_attempt_liveness.Stream_chunk
module T = Agent_sdk.Types

(* ─────────────────────── helpers ─────────────────────── *)

let kind_label = function
  | SC.Thinking_delta -> "thinking_delta"
  | SC.Answer_delta -> "answer_delta"
  | SC.Tool_call_start { tool_name } ->
      Printf.sprintf "tool_call_start(%s)" tool_name
  | SC.Tool_call_arg_delta -> "tool_call_arg_delta"
  | SC.Tool_call_complete -> "tool_call_complete"
  | SC.Substrate_event { kind } -> Printf.sprintf "substrate(%s)" kind
  | SC.Heartbeat -> "heartbeat"
  | SC.Done -> "done"

let check_some name expected evt =
  let label = match A.kind_of_sse_event evt with
    | None -> "none"
    | Some k -> kind_label k
  in
  Alcotest.(check string) name expected label

(* ─────────────────────── ContentBlockDelta ─────────────────────── *)

let test_text_delta_maps_to_answer_delta () =
  let evt = T.ContentBlockDelta {
    index = 0;
    delta = T.TextDelta "hello"
  } in
  check_some "text→answer_delta" "answer_delta" evt

let test_thinking_delta_maps () =
  let evt = T.ContentBlockDelta {
    index = 0;
    delta = T.ThinkingDelta "...thinking..."
  } in
  check_some "thinking" "thinking_delta" evt

let test_input_json_delta_maps_to_tool_arg () =
  let evt = T.ContentBlockDelta {
    index = 1;
    delta = T.InputJsonDelta "{\"a\":1}"
  } in
  check_some "input_json→tool_call_arg" "tool_call_arg_delta" evt

(* ─────────────────────── ContentBlockStart ─────────────────────── *)

let test_tool_use_block_start () =
  let evt = T.ContentBlockStart {
    index = 1;
    content_type = "tool_use";
    tool_id = Some "abc";
    tool_name = Some "shell";
  } in
  check_some "tool_use_start" "tool_call_start(shell)" evt

let test_tool_use_block_start_without_name () =
  let evt = T.ContentBlockStart {
    index = 1;
    content_type = "tool_use";
    tool_id = Some "abc";
    tool_name = None;
  } in
  check_some "tool_use_start_no_name" "tool_call_start()" evt

let test_text_block_start_is_substrate () =
  let evt = T.ContentBlockStart {
    index = 0;
    content_type = "text";
    tool_id = None;
    tool_name = None;
  } in
  check_some "text_block_start"
    "substrate(content_block_start:text)" evt

(* ─────────────────────── lifecycle ─────────────────────── *)

let test_message_start_is_substrate () =
  let evt = T.MessageStart {
    id = "msg_1";
    model = "test-model";
    usage = None;
  } in
  check_some "message_start" "substrate(message_start)" evt

let test_message_delta_is_substrate () =
  let evt = T.MessageDelta {
    stop_reason = None;
    usage = None;
  } in
  check_some "message_delta" "substrate(message_delta)" evt

let test_message_stop_is_done () =
  check_some "message_stop" "done" T.MessageStop

let test_content_block_stop_is_tool_call_complete () =
  let evt = T.ContentBlockStop { index = 1 } in
  check_some "block_stop" "tool_call_complete" evt

let test_ping_is_heartbeat () =
  check_some "ping" "heartbeat" T.Ping

let test_sse_error_is_none () =
  let label = match A.kind_of_sse_event (T.SSEError "boom") with
    | None -> "none"
    | Some k -> kind_label k
  in
  Alcotest.(check string) "sse_error→none" "none" label

(* ─────────────────────── runner ─────────────────────── *)

let () =
  let case name f = Alcotest.test_case name `Quick f in
  Alcotest.run "Cascade_attempt_liveness_oas_adapter"
    [
      ( "ContentBlockDelta",
        [
          case "TextDelta → Answer_delta" test_text_delta_maps_to_answer_delta;
          case "ThinkingDelta → Thinking_delta" test_thinking_delta_maps;
          case "InputJsonDelta → Tool_call_arg_delta"
            test_input_json_delta_maps_to_tool_arg;
        ] );
      ( "ContentBlockStart",
        [
          case "tool_use with name → Tool_call_start"
            test_tool_use_block_start;
          case "tool_use without name → Tool_call_start(empty)"
            test_tool_use_block_start_without_name;
          case "text block → Substrate_event" test_text_block_start_is_substrate;
        ] );
      ( "lifecycle",
        [
          case "MessageStart → Substrate_event" test_message_start_is_substrate;
          case "MessageDelta → Substrate_event" test_message_delta_is_substrate;
          case "MessageStop → Done" test_message_stop_is_done;
          case "ContentBlockStop → Tool_call_complete"
            test_content_block_stop_is_tool_call_complete;
          case "Ping → Heartbeat" test_ping_is_heartbeat;
          case "SSEError → None" test_sse_error_is_none;
        ] );
    ]
