(** Tests for Structured output + SSE streaming integration.

    Verifies that emit_synthetic_events and parse_sse_event compose correctly
    for the structured output streaming pattern (extract_stream). *)

open Agent_sdk
open Types

(* ── Helpers ─────────────────────────────────────────────────────── *)

let make_tool_response ~tool_id ~tool_name ~input_json =
  { id = "msg_test"
  ; model = "claude-sonnet-4"
  ; stop_reason = StopToolUse
  ; content = [ ToolUse { id = tool_id; name = tool_name; input = input_json } ]
  ; usage =
      Some
        { input_tokens = 50
        ; output_tokens = 20
        ; cache_creation_input_tokens = 0
        ; cache_read_input_tokens = 0
        ; cost_usd = None
        }
  ; telemetry = None
  }
;;

(** Build a proper SSE data JSON for an InputJsonDelta event.
    Uses Yojson to handle escaping correctly. *)
let make_delta_data index partial_json =
  Yojson.Safe.to_string
    (`Assoc
        [ "type", `String "content_block_delta"
        ; "index", `Int index
        ; ( "delta"
          , `Assoc
              [ "type", `String "input_json_delta"; "partial_json", `String partial_json ]
          )
        ])
;;

(* ── 1. synthetic_events_for_tool_use ────────────────────────────── *)

let test_synthetic_events_for_tool_use () =
  let input_json = `Assoc [ "name", `String "Bob"; "age", `Int 25 ] in
  let response =
    make_tool_response ~tool_id:"tu_1" ~tool_name:"extract_person" ~input_json
  in
  let events = ref [] in
  Llm_provider.Streaming.emit_synthetic_events response (fun e -> events := e :: !events);
  let events = List.rev !events in
  (* MessageStart → ContentBlockStart → ContentBlockDelta → ContentBlockStop
     → MessageDelta → MessageStop = 6 events *)
  Alcotest.(check int) "6 events" 6 (List.length events);
  (match List.nth events 0 with
   | MessageStart { id; model; _ } ->
     Alcotest.(check string) "id" "msg_test" id;
     Alcotest.(check string) "model" "claude-sonnet-4" model
   | _ -> Alcotest.fail "expected MessageStart");
  (match List.nth events 1 with
   | ContentBlockStart { index; content_type; tool_id; tool_name } ->
     Alcotest.(check int) "index" 0 index;
     Alcotest.(check string) "type" "tool_use" content_type;
     Alcotest.(check bool) "tool_id" true (tool_id = Some "tu_1");
     Alcotest.(check bool) "tool_name" true (tool_name = Some "extract_person")
   | _ -> Alcotest.fail "expected ContentBlockStart");
  (match List.nth events 2 with
   | ContentBlockDelta { index; delta = InputJsonSnapshot _ } ->
     Alcotest.(check int) "delta index" 0 index
   | _ -> Alcotest.fail "expected InputJsonSnapshot");
  (match List.nth events 3 with
   | ContentBlockStop { index } -> Alcotest.(check int) "stop" 0 index
   | _ -> Alcotest.fail "expected ContentBlockStop");
  (match List.nth events 4 with
   | MessageDelta { stop_reason; _ } ->
     Alcotest.(check bool) "stop_reason" true (stop_reason = Some StopToolUse)
   | _ -> Alcotest.fail "expected MessageDelta");
  match List.nth events 5 with
  | MessageStop -> ()
  | _ -> Alcotest.fail "expected MessageStop"
;;

(* ── 2. on_event_callback_fires ──────────────────────────────────── *)

let test_on_event_callback_fires () =
  let input_json = `Assoc [ "name", `String "Eve"; "age", `Int 30 ] in
  let response =
    { id = "msg_2"
    ; model = "claude-sonnet-4"
    ; stop_reason = StopToolUse
    ; content =
        [ Text "thinking..."
        ; ToolUse { id = "tu_2"; name = "extract_person"; input = input_json }
        ]
    ; usage =
        Some
          { input_tokens = 100
          ; output_tokens = 50
          ; cache_creation_input_tokens = 0
          ; cache_read_input_tokens = 0
          ; cost_usd = None
          }
    ; telemetry = None
    }
  in
  let event_types = ref [] in
  Llm_provider.Streaming.emit_synthetic_events response (fun e ->
    let t =
      match e with
      | MessageStart _ -> "message_start"
      | ContentBlockStart _ -> "content_block_start"
      | ContentBlockDelta _ -> "content_block_delta"
      | ContentBlockStop _ -> "content_block_stop"
      | MessageDelta _ -> "message_delta"
      | MessageStop -> "message_stop"
      | Ping -> "ping"
      | SSEError _ -> "error"
      | NDJSONError _ -> "error"
      | SSEParseFailed _ -> "parse_failed"
      | NDJSONParseFailed _ -> "ndjson_parse_failed"
      | SSEUnknownEventType _ -> "unknown_event_type"
      | SSEUnsupportedPart _ -> "unsupported_part"
      | SSEUnsupportedResponse _ -> "unsupported_response"
      | Connected -> "connected"
      | Timeout _ -> "timeout"
      | StreamIncomplete _ -> "stream_incomplete"
    in
    event_types := t :: !event_types);
  let types = List.rev !event_types in
  (* 2 content blocks × (start+delta+stop) = 6, plus MessageStart+MessageDelta+MessageStop = 9 *)
  Alcotest.(check int) "9 events for 2 blocks" 9 (List.length types);
  Alcotest.(check string) "first" "message_start" (List.hd types);
  Alcotest.(check string) "last" "message_stop" (List.nth types 8)
;;

(* ── 3. tool_use_json_parseable ──────────────────────────────────── *)

let test_tool_use_json_parseable () =
  let input_json = `Assoc [ "name", `String "Alice"; "age", `Int 30 ] in
  let response =
    make_tool_response ~tool_id:"tu_3" ~tool_name:"extract_person" ~input_json
  in
  let json_parts = ref [] in
  Llm_provider.Streaming.emit_synthetic_events response (fun e ->
    match e with
    | ContentBlockDelta { delta = InputJsonSnapshot s; _ } ->
      json_parts := s :: !json_parts
    | _ -> ());
  let combined = String.concat "" (List.rev !json_parts) in
  try
    let parsed = Yojson.Safe.from_string combined in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "name" "Alice" (parsed |> member "name" |> to_string);
    Alcotest.(check int) "age" 30 (parsed |> member "age" |> to_int)
  with
  | Yojson.Json_error e -> Alcotest.fail ("Invalid JSON: " ^ e)
;;

(* ── 4. multiple_schemas ─────────────────────────────────────────── *)

let test_accumulate_json_deltas () =
  let parts = [ {|{"name"|}; {|: "Alice"|}; {|, "age": 30}|} ] in
  let buf = Buffer.create 64 in
  List.iter
    (fun part ->
       let data = make_delta_data 0 part in
       match Llm_provider.Streaming.parse_sse_event None data with
       | Some (ContentBlockDelta { delta = InputJsonDelta s; _ }) ->
         Buffer.add_string buf s
       | _ -> Alcotest.fail "expected InputJsonDelta")
    parts;
  let combined = Buffer.contents buf in
  let parsed = Yojson.Safe.from_string combined in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "name" "Alice" (parsed |> member "name" |> to_string);
  Alcotest.(check int) "age" 30 (parsed |> member "age" |> to_int)
;;

(* ── 6. accumulate_empty_delta ───────────────────────────────────── *)

let test_accumulate_empty_delta () =
  let data = make_delta_data 0 "" in
  match Llm_provider.Streaming.parse_sse_event None data with
  | Some (ContentBlockDelta { delta = InputJsonDelta s; _ }) ->
    Alcotest.(check string) "empty partial" "" s
  | _ -> Alcotest.fail "expected InputJsonDelta for empty string"
;;

(* ── 7. accumulate_partial_then_complete ─────────────────────────── *)

let test_accumulate_partial_then_complete () =
  let parts = [ {|{"col|}; {|or": "|}; {|red"}|} ] in
  let buf = Buffer.create 64 in
  List.iter
    (fun part ->
       let data = make_delta_data 0 part in
       match Llm_provider.Streaming.parse_sse_event None data with
       | Some (ContentBlockDelta { delta = InputJsonDelta s; _ }) ->
         Buffer.add_string buf s
       | _ -> Alcotest.fail "expected InputJsonDelta")
    parts;
  let combined = Buffer.contents buf in
  let parsed = Yojson.Safe.from_string combined in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "color" "red" (parsed |> member "color" |> to_string)
;;

(* ── 8. extract_after_accumulation ───────────────────────────────── *)

let () =
  Alcotest.run
    "structured_stream"
    [ ( "synthetic_events"
      , [ Alcotest.test_case "tool_use sequence" `Quick test_synthetic_events_for_tool_use
        ; Alcotest.test_case "callback fires" `Quick test_on_event_callback_fires
        ; Alcotest.test_case "json parseable" `Quick test_tool_use_json_parseable
        ] )
    ; ( "delta_accumulation"
      , [ Alcotest.test_case "multi-fragment" `Quick test_accumulate_json_deltas
        ; Alcotest.test_case "empty delta" `Quick test_accumulate_empty_delta
        ; Alcotest.test_case
            "partial then complete"
            `Quick
            test_accumulate_partial_then_complete
        ] )
    ]
;;
