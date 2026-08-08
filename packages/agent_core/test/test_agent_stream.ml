(** Unit tests for streaming agent integration: emit_synthetic_events.
    Tests verify event sequences produced by
    Llm_provider.Streaming.emit_synthetic_events for various api_response
    shapes. *)

open Agent_sdk

(* ------------------------------------------------------------------ *)
(* Helpers                                                              *)
(* ------------------------------------------------------------------ *)

(** Collect all events emitted for a given response. *)
let collect_events response =
  let events = ref [] in
  Llm_provider.Streaming.emit_synthetic_events response (fun evt ->
    events := evt :: !events);
  List.rev !events
;;

let make_usage ?(inp = 0) ?(out = 0) ?(cc = 0) ?(cr = 0) () : Types.api_usage =
  { input_tokens = inp
  ; output_tokens = out
  ; cache_creation_input_tokens = cc
  ; cache_read_input_tokens = cr
  ; cost_usd = None
  }
;;

let make_response
      ?(id = "msg-1")
      ?(model = "test-model")
      ?(stop_reason = Types.EndTurn)
      ?(usage = Some (make_usage ~inp:10 ~out:5 ()))
      content
  : Types.api_response
  =
  { id; model; stop_reason; content; usage; telemetry = None }
;;

(** Count events of a specific kind. *)
let count_kind events pred = List.length (List.filter pred events)

(* ------------------------------------------------------------------ *)
(* 1-4: Basic content type emission                                     *)
(* ------------------------------------------------------------------ *)

let test_emit_text_only () =
  let response = make_response [ Types.Text "hello world" ] in
  let events = collect_events response in
  Alcotest.(check int) "6 events" 6 (List.length events);
  (match List.nth events 0 with
   | Types.MessageStart { id; _ } -> Alcotest.(check string) "id" "msg-1" id
   | _ -> Alcotest.fail "expected MessageStart");
  match List.nth events 2 with
  | Types.ContentBlockDelta { delta = Types.TextDelta s; _ } ->
    Alcotest.(check string) "text content" "hello world" s
  | _ -> Alcotest.fail "expected TextDelta"
;;

let test_emit_tool_use () =
  let input = `Assoc [ "location", `String "Seoul" ] in
  let response =
    make_response
      ~stop_reason:Types.StopToolUse
      [ Types.ToolUse { id = "tool-1"; name = "get_weather"; input } ]
  in
  let events = collect_events response in
  Alcotest.(check int) "6 events" 6 (List.length events);
  (match List.nth events 1 with
   | Types.ContentBlockStart { content_type; tool_id; tool_name; _ } ->
     Alcotest.(check string) "content_type" "tool_use" content_type;
     Alcotest.(check (option string)) "tool_id" (Some "tool-1") tool_id;
     Alcotest.(check (option string)) "tool_name" (Some "get_weather") tool_name
   | _ -> Alcotest.fail "expected ContentBlockStart with tool_use");
  match List.nth events 2 with
  | Types.ContentBlockDelta { delta = Types.InputJsonSnapshot s; _ } ->
    let _parsed = Yojson.Safe.from_string s in
    Alcotest.(check bool) "valid JSON" true true
  | _ -> Alcotest.fail "expected InputJsonSnapshot"
;;

let test_emit_thinking () =
  let response =
    make_response [ Types.Thinking { signature = Some "sig"; content = "I think..." } ]
  in
  let events = collect_events response in
  Alcotest.(check int) "7 events" 7 (List.length events);
  (match List.nth events 1 with
   | Types.ContentBlockStart { content_type; _ } ->
     Alcotest.(check string) "content_type" "thinking" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart with thinking");
  (match List.nth events 2 with
   | Types.ContentBlockDelta { delta = Types.ThinkingDelta s; _ } ->
     Alcotest.(check string) "thinking content" "I think..." s
   | _ -> Alcotest.fail "expected ThinkingDelta");
  match List.nth events 3 with
  | Types.ContentBlockDelta { delta = Types.ThinkingSignatureDelta s; _ } ->
    Alcotest.(check string) "thinking signature" "sig" s
  | _ -> Alcotest.fail "expected ThinkingSignatureDelta"
;;

let test_emit_multiple_blocks () =
  let response =
    make_response
      [ Types.Text "Here is the result:"
      ; Types.ToolUse { id = "t1"; name = "calc"; input = `Assoc [ "x", `Int 42 ] }
      ]
  in
  let events = collect_events response in
  (* MessageStart + (CBS+CBD+CBStop)*2 + MessageDelta + MessageStop = 1+3+3+1+1=9 *)
  Alcotest.(check int) "9 events" 9 (List.length events);
  let cbs_count =
    count_kind events (function
      | Types.ContentBlockStart _ -> true
      | _ -> false)
  in
  Alcotest.(check int) "2 ContentBlockStarts" 2 cbs_count
;;

(* ------------------------------------------------------------------ *)
(* 5-8: Event structure properties                                      *)
(* ------------------------------------------------------------------ *)

let test_event_order () =
  let response = make_response [ Types.Text "hi" ] in
  let events = collect_events response in
  (* Order: MessageStart, CBS, CBD, CBStop, MessageDelta, MessageStop *)
  (match List.nth events 0 with
   | Types.MessageStart _ -> ()
   | _ -> Alcotest.fail "first: MessageStart");
  (match List.nth events 1 with
   | Types.ContentBlockStart _ -> ()
   | _ -> Alcotest.fail "second: ContentBlockStart");
  (match List.nth events 2 with
   | Types.ContentBlockDelta _ -> ()
   | _ -> Alcotest.fail "third: ContentBlockDelta");
  (match List.nth events 3 with
   | Types.ContentBlockStop _ -> ()
   | _ -> Alcotest.fail "fourth: ContentBlockStop");
  (match List.nth events 4 with
   | Types.MessageDelta _ -> ()
   | _ -> Alcotest.fail "fifth: MessageDelta");
  match List.nth events 5 with
  | Types.MessageStop -> ()
  | _ -> Alcotest.fail "sixth: MessageStop"
;;

let test_message_start_has_usage () =
  let usage = make_usage ~inp:100 ~out:50 () in
  let response = make_response ~usage:(Some usage) [ Types.Text "x" ] in
  let events = collect_events response in
  match List.nth events 0 with
  | Types.MessageStart { usage = Some u; _ } ->
    Alcotest.(check int) "input_tokens" 100 u.input_tokens;
    Alcotest.(check int) "output_tokens" 50 u.output_tokens
  | Types.MessageStart { usage = None; _ } -> Alcotest.fail "expected Some usage"
  | _ -> Alcotest.fail "expected MessageStart"
;;

let test_message_delta_has_stop_reason () =
  let response = make_response ~stop_reason:Types.MaxTokens [ Types.Text "trunc" ] in
  let events = collect_events response in
  let md = List.nth events (List.length events - 2) in
  match md with
  | Types.MessageDelta { stop_reason = Some Types.MaxTokens; _ } -> ()
  | _ -> Alcotest.fail "expected MessageDelta with MaxTokens"
;;

let test_message_stop_last () =
  let response = make_response [ Types.Text "done" ] in
  let events = collect_events response in
  let last = List.nth events (List.length events - 1) in
  match last with
  | Types.MessageStop -> ()
  | _ -> Alcotest.fail "last event should be MessageStop"
;;

(* ------------------------------------------------------------------ *)
(* 9-12: Edge cases                                                     *)
(* ------------------------------------------------------------------ *)

let test_emit_empty_content () =
  let response = make_response [] in
  let events = collect_events response in
  (* MessageStart + MessageDelta + MessageStop = 3 *)
  Alcotest.(check int) "3 events for empty content" 3 (List.length events);
  (match List.nth events 0 with
   | Types.MessageStart _ -> ()
   | _ -> Alcotest.fail "MessageStart");
  (match List.nth events 1 with
   | Types.MessageDelta _ -> ()
   | _ -> Alcotest.fail "MessageDelta");
  match List.nth events 2 with
  | Types.MessageStop -> ()
  | _ -> Alcotest.fail "MessageStop"
;;

let test_tool_use_has_ids () =
  let response =
    make_response [ Types.ToolUse { id = "id-abc"; name = "my_tool"; input = `Assoc [] } ]
  in
  let events = collect_events response in
  match List.nth events 1 with
  | Types.ContentBlockStart { tool_id = Some "id-abc"; tool_name = Some "my_tool"; _ } ->
    ()
  | _ -> Alcotest.fail "expected tool_id and tool_name in ContentBlockStart"
;;

let test_content_block_indices_sequential () =
  let response = make_response [ Types.Text "a"; Types.Text "b"; Types.Text "c" ] in
  let events = collect_events response in
  let indices =
    List.filter_map
      (function
        | Types.ContentBlockStart { index; _ } -> Some index
        | _ -> None)
      events
  in
  Alcotest.(check (list int)) "sequential indices" [ 0; 1; 2 ] indices
;;

let test_text_delta_content () =
  let long_text = String.make 1000 'x' in
  let response = make_response [ Types.Text long_text ] in
  let events = collect_events response in
  match List.nth events 2 with
  | Types.ContentBlockDelta { delta = Types.TextDelta s; _ } ->
    Alcotest.(check int) "text length preserved" 1000 (String.length s)
  | _ -> Alcotest.fail "expected TextDelta"
;;

(* ------------------------------------------------------------------ *)
(* 13-16: Content delta types                                           *)
(* ------------------------------------------------------------------ *)

let test_thinking_delta_content () =
  let response =
    make_response
      [ Types.Thinking { signature = Some "sig123"; content = "deep thought" } ]
  in
  let events = collect_events response in
  match List.nth events 2 with
  | Types.ContentBlockDelta { delta = Types.ThinkingDelta s; _ } ->
    Alcotest.(check string) "thinking text" "deep thought" s
  | _ -> Alcotest.fail "expected ThinkingDelta"
;;

let test_input_json_snapshot_content () =
  let input = `Assoc [ "key", `String "value"; "num", `Int 42 ] in
  let response =
    make_response
      ~stop_reason:Types.StopToolUse
      [ Types.ToolUse { id = "t1"; name = "fn"; input } ]
  in
  let events = collect_events response in
  match List.nth events 2 with
  | Types.ContentBlockDelta { delta = Types.InputJsonSnapshot s; _ } ->
    let parsed = Yojson.Safe.from_string s in
    let key = Yojson.Safe.Util.(parsed |> member "key" |> to_string) in
    Alcotest.(check string) "parsed key" "value" key
  | _ -> Alcotest.fail "expected InputJsonSnapshot"
;;

let test_image_block_media_delta () =
  let response =
    make_response
      [ Types.Image
          { media_type = "image/png"; data = "base64data"; source_type = Types.Base64 }
      ]
  in
  let events = collect_events response in
  (match List.nth events 1 with
   | Types.ContentBlockStart { content_type; tool_id = None; tool_name = None; _ } ->
     Alcotest.(check string) "image block type" "image" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart");
  (match List.nth events 2 with
   | Types.ContentBlockDelta
       { delta = Types.MediaDelta { media_type; source_type; data }; _ } ->
     Alcotest.(check string) "image media type" "image/png" media_type;
     Alcotest.(check string)
       "image source type"
       "base64"
       (Types.media_source_kind_to_string source_type);
     Alcotest.(check string) "image data" "base64data" data
   | _ -> Alcotest.fail "expected image MediaDelta");
  Alcotest.(check int) "6 events" 6 (List.length events)
;;

let test_document_block_media_delta () =
  let response =
    make_response
      [ Types.Document
          { media_type = "application/pdf"; data = "pdfdata"; source_type = Types.Base64 }
      ]
  in
  let events = collect_events response in
  (match List.nth events 1 with
   | Types.ContentBlockStart { content_type; _ } ->
     Alcotest.(check string) "document block type" "document" content_type
   | _ -> Alcotest.fail "expected ContentBlockStart");
  (match List.nth events 2 with
   | Types.ContentBlockDelta
       { delta = Types.MediaDelta { media_type; source_type; data }; _ } ->
     Alcotest.(check string) "document media type" "application/pdf" media_type;
     Alcotest.(check string)
       "document source type"
       "base64"
       (Types.media_source_kind_to_string source_type);
     Alcotest.(check string) "document data" "pdfdata" data
   | _ -> Alcotest.fail "expected document MediaDelta");
  Alcotest.(check int) "6 events" 6 (List.length events)
;;

(* ------------------------------------------------------------------ *)
(* 17-20: Parse + emit roundtrip consistency                            *)
(* ------------------------------------------------------------------ *)

let test_roundtrip_text_event_count () =
  (* Verify that emit produces the same number of ContentBlockDelta events
     as parse_sse_event would generate for a single text block *)
  let response = make_response [ Types.Text "hello" ] in
  let events = collect_events response in
  let cbd_count =
    count_kind events (function
      | Types.ContentBlockDelta _ -> true
      | _ -> false)
  in
  Alcotest.(check int) "1 delta per text block" 1 cbd_count
;;

let test_roundtrip_tool_event_count () =
  let response =
    make_response
      ~stop_reason:Types.StopToolUse
      [ Types.ToolUse { id = "t1"; name = "fn"; input = `Assoc [] } ]
  in
  let events = collect_events response in
  let cbd_count =
    count_kind events (function
      | Types.ContentBlockDelta _ -> true
      | _ -> false)
  in
  Alcotest.(check int) "1 delta per tool_use block" 1 cbd_count
;;

let test_roundtrip_mixed_block_count () =
  let response =
    make_response
      [ Types.Text "intro"
      ; Types.Thinking { signature = Some "sig"; content = "hmm" }
      ; Types.Text "conclusion"
      ]
  in
  let events = collect_events response in
  let cbd_count =
    count_kind events (function
      | Types.ContentBlockDelta _ -> true
      | _ -> false)
  in
  Alcotest.(check int) "4 deltas for 3 blocks plus thinking signature" 4 cbd_count
;;

let test_roundtrip_message_start_fields () =
  let response = make_response ~id:"msg-xyz" ~model:"claude-test" [ Types.Text "x" ] in
  let events = collect_events response in
  match List.nth events 0 with
  | Types.MessageStart { id; model; _ } ->
    Alcotest.(check string) "id preserved" "msg-xyz" id;
    Alcotest.(check string) "model preserved" "claude-test" model
  | _ -> Alcotest.fail "expected MessageStart"
;;

(* ------------------------------------------------------------------ *)
(* 21-24: Different stop_reasons                                        *)
(* ------------------------------------------------------------------ *)

let test_emit_stop_reason_end_turn () =
  let response = make_response ~stop_reason:Types.EndTurn [ Types.Text "done" ] in
  let events = collect_events response in
  let md = List.nth events (List.length events - 2) in
  match md with
  | Types.MessageDelta { stop_reason = Some Types.EndTurn; _ } -> ()
  | _ -> Alcotest.fail "expected EndTurn"
;;

let test_emit_stop_reason_max_tokens () =
  let response = make_response ~stop_reason:Types.MaxTokens [ Types.Text "trunc" ] in
  let events = collect_events response in
  let md = List.nth events (List.length events - 2) in
  match md with
  | Types.MessageDelta { stop_reason = Some Types.MaxTokens; _ } -> ()
  | _ -> Alcotest.fail "expected MaxTokens"
;;

let test_emit_stop_reason_stop_tool_use () =
  let response =
    make_response
      ~stop_reason:Types.StopToolUse
      [ Types.ToolUse { id = "t1"; name = "fn"; input = `Null } ]
  in
  let events = collect_events response in
  let md = List.nth events (List.length events - 2) in
  match md with
  | Types.MessageDelta { stop_reason = Some Types.StopToolUse; _ } -> ()
  | _ -> Alcotest.fail "expected StopToolUse"
;;

let test_emit_stop_reason_stop_sequence () =
  let response = make_response ~stop_reason:Types.StopSequence [ Types.Text "stop" ] in
  let events = collect_events response in
  let md = List.nth events (List.length events - 2) in
  match md with
  | Types.MessageDelta { stop_reason = Some Types.StopSequence; _ } -> ()
  | _ -> Alcotest.fail "expected StopSequence"
;;

(* ------------------------------------------------------------------ *)
(* 25-28: Edge cases for response fields                                *)
(* ------------------------------------------------------------------ *)

let test_emit_none_usage () =
  let response = make_response ~usage:None [ Types.Text "no usage" ] in
  let events = collect_events response in
  (match List.nth events 0 with
   | Types.MessageStart { usage = None; _ } -> ()
   | _ -> Alcotest.fail "expected None usage in MessageStart");
  let md = List.nth events (List.length events - 2) in
  match md with
  | Types.MessageDelta { usage = None; _ } -> ()
  | _ -> Alcotest.fail "expected None usage in MessageDelta"
;;

let test_emit_empty_model () =
  let response = make_response ~model:"" [ Types.Text "x" ] in
  let events = collect_events response in
  match List.nth events 0 with
  | Types.MessageStart { model; _ } -> Alcotest.(check string) "empty model" "" model
  | _ -> Alcotest.fail "expected MessageStart"
;;

let test_emit_empty_id () =
  let response = make_response ~id:"" [ Types.Text "x" ] in
  let events = collect_events response in
  match List.nth events 0 with
  | Types.MessageStart { id; _ } -> Alcotest.(check string) "empty id" "" id
  | _ -> Alcotest.fail "expected MessageStart"
;;

let test_emit_multiple_tool_uses () =
  let response =
    make_response
      ~stop_reason:Types.StopToolUse
      [ Types.ToolUse { id = "t1"; name = "fn1"; input = `Assoc [ "a", `Int 1 ] }
      ; Types.ToolUse { id = "t2"; name = "fn2"; input = `Assoc [ "b", `Int 2 ] }
      ]
  in
  let events = collect_events response in
  (* MessageStart + (CBS+CBD+CBStop)*2 + MessageDelta + MessageStop = 9 *)
  Alcotest.(check int) "9 events" 9 (List.length events);
  let tool_starts =
    List.filter_map
      (function
        | Types.ContentBlockStart { content_type = "tool_use"; tool_id; tool_name; _ } ->
          Some (tool_id, tool_name)
        | _ -> None)
      events
  in
  Alcotest.(check int) "2 tool starts" 2 (List.length tool_starts);
  let first_id, first_name = List.nth tool_starts 0 in
  let second_id, second_name = List.nth tool_starts 1 in
  Alcotest.(check (option string)) "first tool_id" (Some "t1") first_id;
  Alcotest.(check (option string)) "first tool_name" (Some "fn1") first_name;
  Alcotest.(check (option string)) "second tool_id" (Some "t2") second_id;
  Alcotest.(check (option string)) "second tool_name" (Some "fn2") second_name
;;

(* ------------------------------------------------------------------ *)
(* Test runner                                                          *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run
    "agent_stream"
    [ ( "emit_basic"
      , [ test_case "text_only" `Quick test_emit_text_only
        ; test_case "tool_use" `Quick test_emit_tool_use
        ; test_case "thinking" `Quick test_emit_thinking
        ; test_case "multiple_blocks" `Quick test_emit_multiple_blocks
        ] )
    ; ( "emit_structure"
      , [ test_case "event_order" `Quick test_event_order
        ; test_case "message_start_has_usage" `Quick test_message_start_has_usage
        ; test_case
            "message_delta_has_stop_reason"
            `Quick
            test_message_delta_has_stop_reason
        ; test_case "message_stop_last" `Quick test_message_stop_last
        ] )
    ; ( "emit_edge_cases"
      , [ test_case "empty_content" `Quick test_emit_empty_content
        ; test_case "tool_use_has_ids" `Quick test_tool_use_has_ids
        ; test_case
            "content_block_indices_sequential"
            `Quick
            test_content_block_indices_sequential
        ; test_case "text_delta_content" `Quick test_text_delta_content
        ] )
    ; ( "emit_delta_types"
      , [ test_case "thinking_delta_content" `Quick test_thinking_delta_content
        ; test_case "input_json_snapshot_content" `Quick test_input_json_snapshot_content
        ; test_case "image_block_media_delta" `Quick test_image_block_media_delta
        ; test_case "document_block_media_delta" `Quick test_document_block_media_delta
        ] )
    ; ( "emit_roundtrip"
      , [ test_case "text_event_count" `Quick test_roundtrip_text_event_count
        ; test_case "tool_event_count" `Quick test_roundtrip_tool_event_count
        ; test_case "mixed_block_count" `Quick test_roundtrip_mixed_block_count
        ; test_case "message_start_fields" `Quick test_roundtrip_message_start_fields
        ] )
    ; ( "emit_stop_reasons"
      , [ test_case "end_turn" `Quick test_emit_stop_reason_end_turn
        ; test_case "max_tokens" `Quick test_emit_stop_reason_max_tokens
        ; test_case "stop_tool_use" `Quick test_emit_stop_reason_stop_tool_use
        ; test_case "stop_sequence" `Quick test_emit_stop_reason_stop_sequence
        ] )
    ; ( "emit_field_edge_cases"
      , [ test_case "none_usage" `Quick test_emit_none_usage
        ; test_case "empty_model" `Quick test_emit_empty_model
        ; test_case "empty_id" `Quick test_emit_empty_id
        ; test_case "multiple_tool_uses" `Quick test_emit_multiple_tool_uses
        ] )
    ]
;;
