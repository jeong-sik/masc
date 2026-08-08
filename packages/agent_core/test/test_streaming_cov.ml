(** Extended Streaming coverage tests — targets uncovered paths in
    llm_provider/streaming.ml, llm_provider/complete_stream_acc.ml, and
    llm_provider/complete.ml.

    Focuses on:
    - stream_acc creation and accumulation
    - finalize_stream_acc with various event sequences
    - accumulate_event for each event type *)

open Agent_sdk

(* [lib/streaming.ml]'s stream-accumulator/SSE-parse surface was a
   straight re-export of these two modules; call sites below still read
   [Streaming.*] against that combined surface directly. *)
module Streaming = struct
  include Llm_provider.Streaming
  include Llm_provider.Complete_stream_acc
end

let stream_error_to_string = function
  | Types.Stream_provider_error { message; _ } -> message
  | Types.Stream_parse_failed { reason; _ } -> reason
  | Types.Stream_ndjson_parse_failed { reason; _ } -> reason
  | Types.Stream_incomplete { reason } -> reason
  | Types.Stream_unknown_event { event_type; _ } -> "unknown_event:" ^ event_type
  | Types.Stream_unsupported_part { part; _ } -> "unsupported_part:" ^ part
  | Types.Stream_unsupported_response { response; _ } ->
    "unsupported_response:" ^ response
;;

let fail_unexpected_stream_error err =
  Alcotest.fail ("unexpected SSE error: " ^ stream_error_to_string err)
;;

let check_zero_usage = function
  | Some (u : Types.api_usage) ->
    Alcotest.(check int) "input" 0 u.input_tokens;
    Alcotest.(check int) "output" 0 u.output_tokens;
    Alcotest.(check int) "cache_creation" 0 u.cache_creation_input_tokens;
    Alcotest.(check int) "cache_read" 0 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected zero usage"
;;

(** Unwrap finalize result or fail the test. *)
let finalize_ok acc =
  if not !(acc.Streaming.stop_reason_received)
  then
    Streaming.accumulate_event
      acc
      (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Ok resp -> resp
  | Error err -> fail_unexpected_stream_error err
;;

(* ── stream_acc creation ──────────────────────────────────── *)

let test_create_stream_acc () =
  let acc = Streaming.create_stream_acc () in
  Alcotest.(check string) "empty id" "" !(acc.id);
  Alcotest.(check string) "empty model" "" !(acc.model);
  Alcotest.(check int) "zero input" 0 !(acc.input_tokens);
  Alcotest.(check int) "zero output" 0 !(acc.output_tokens)
;;

(* ── accumulate_event tests ───────────────────────────────── *)

let test_accumulate_message_start () =
  let acc = Streaming.create_stream_acc () in
  let usage : Types.api_usage =
    { input_tokens = 10
    ; output_tokens = 0
    ; cache_creation_input_tokens = 2
    ; cache_read_input_tokens = 3
    ; cost_usd = None
    }
  in
  Streaming.accumulate_event
    acc
    (Types.MessageStart { id = "msg_1"; model = "claude-3"; usage = Some usage });
  Alcotest.(check string) "id" "msg_1" !(acc.id);
  Alcotest.(check string) "model" "claude-3" !(acc.model);
  Alcotest.(check int) "input tokens" 10 !(acc.input_tokens);
  Alcotest.(check int) "cache creation" 2 !(acc.cache_creation);
  Alcotest.(check int) "cache read" 3 !(acc.cache_read)
;;

let test_accumulate_message_start_no_usage () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.MessageStart { id = "msg_2"; model = "gpt-4"; usage = None });
  Alcotest.(check string) "id" "msg_2" !(acc.id);
  Alcotest.(check int) "input still 0" 0 !(acc.input_tokens)
;;

let test_accumulate_content_block_start () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  Alcotest.(check bool) "type registered" true (Hashtbl.mem acc.block_types 0);
  Alcotest.(check bool) "text buf exists" true (Hashtbl.mem acc.block_texts 0)
;;

let test_accumulate_content_block_start_tool () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 1
       ; content_type = "tool_use"
       ; tool_id = Some "tu_1"
       ; tool_name = Some "read_file"
       });
  Alcotest.(check bool) "tool_id registered" true (Hashtbl.mem acc.block_tool_ids 1);
  Alcotest.(check bool) "tool_name registered" true (Hashtbl.mem acc.block_tool_names 1)
;;

let test_accumulate_content_block_delta_text () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "hello " });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "world" });
  match Hashtbl.find_opt acc.block_texts 0 with
  | Some buf -> Alcotest.(check string) "text" "hello world" (Buffer.contents buf)
  | None -> Alcotest.fail "expected text buffer"
;;

let test_accumulate_content_block_delta_thinking () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.ThinkingDelta "reasoning..." });
  match Hashtbl.find_opt acc.block_texts 0 with
  | Some buf -> Alcotest.(check string) "thinking" "reasoning..." (Buffer.contents buf)
  | None -> Alcotest.fail "expected thinking buffer"
;;

let test_accumulate_content_block_delta_json () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = Some "t1"
       ; tool_name = Some "tool"
       });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta {|{"key":"|} });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta {|val"}|} });
  match Hashtbl.find_opt acc.block_texts 0 with
  | Some buf -> Alcotest.(check string) "json" {|{"key":"val"}|} (Buffer.contents buf)
  | None -> Alcotest.fail "expected json buffer"
;;

let test_accumulate_content_block_delta_new_index () =
  let acc = Streaming.create_stream_acc () in
  (* Delta for index without prior ContentBlockStart *)
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 5; delta = Types.TextDelta "orphan" });
  match Hashtbl.find_opt acc.block_texts 5 with
  | Some buf -> Alcotest.(check string) "orphan text" "orphan" (Buffer.contents buf)
  | None -> Alcotest.fail "expected buffer for new index"
;;

let test_accumulate_message_delta () =
  let acc = Streaming.create_stream_acc () in
  let usage : Types.api_usage =
    { input_tokens = 0
    ; output_tokens = 50
    ; cache_creation_input_tokens = 1
    ; cache_read_input_tokens = 2
    ; cost_usd = None
    }
  in
  Streaming.accumulate_event
    acc
    (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = Some usage });
  Alcotest.(check int) "output tokens" 50 !(acc.output_tokens);
  Alcotest.(check int) "cache creation" 1 !(acc.cache_creation);
  Alcotest.(check int) "cache read" 2 !(acc.cache_read)
;;

let test_accumulate_message_delta_no_usage () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event acc (Types.MessageDelta { stop_reason = None; usage = None });
  Alcotest.(check int) "output still 0" 0 !(acc.output_tokens)
;;

let test_accumulate_other_events () =
  let acc = Streaming.create_stream_acc () in
  (* These should be no-ops *)
  Streaming.accumulate_event acc (Types.ContentBlockStop { index = 0 });
  Streaming.accumulate_event acc Types.MessageStop;
  Streaming.accumulate_event acc Types.Ping;
  Streaming.accumulate_event
    acc
    (Types.SSEError { message = "test error"; error_type = None; raw = "test error" });
  Alcotest.(check string) "id unchanged" "" !(acc.id)
;;

(* ── finalize_stream_acc ──────────────────────────────────── *)

let test_finalize_text_only () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.MessageStart { id = "m1"; model = "model"; usage = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "hello" });
  let resp = finalize_ok acc in
  Alcotest.(check string) "id" "m1" resp.id;
  Alcotest.(check string) "model" "model" resp.model;
  Alcotest.(check int) "one content" 1 (List.length resp.content);
  match resp.content with
  | [ Types.Text "hello" ] -> ()
  | _ -> Alcotest.fail "expected Text hello"
;;

let test_finalize_with_tool_use () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.MessageStart { id = "m2"; model = "m"; usage = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = Some "tu_1"
       ; tool_name = Some "read"
       });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta
       { index = 0; delta = Types.InputJsonDelta {|{"path":"/tmp"}|} });
  let resp = finalize_ok acc in
  match resp.content with
  | [ Types.ToolUse { id; name; _ } ] ->
    Alcotest.(check string) "tool id" "tu_1" id;
    Alcotest.(check string) "tool name" "read" name
  | _ -> Alcotest.fail "expected ToolUse"
;;

let test_finalize_with_thinking () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.MessageStart { id = "m3"; model = "m"; usage = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.ThinkingDelta "I think..." });
  let resp = finalize_ok acc in
  match resp.content with
  | [ Types.Thinking { content; _ } ] ->
    Alcotest.(check string) "thinking" "I think..." content
  | _ -> Alcotest.fail "expected Thinking block"
;;

let test_finalize_with_usage () =
  let acc = Streaming.create_stream_acc () in
  let usage : Types.api_usage =
    { input_tokens = 100
    ; output_tokens = 50
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
  in
  Streaming.accumulate_event
    acc
    (Types.MessageStart { id = "m4"; model = "m"; usage = Some usage });
  Streaming.accumulate_event
    acc
    (Types.MessageDelta
       { stop_reason = Some Types.EndTurn
       ; usage =
           Some
             { input_tokens = 0
             ; output_tokens = 50
             ; cache_creation_input_tokens = 0
             ; cache_read_input_tokens = 0
             ; cost_usd = None
             }
       });
  let resp = finalize_ok acc in
  match resp.usage with
  | Some u ->
    Alcotest.(check int) "input" 100 u.input_tokens;
    Alcotest.(check int) "output" 50 u.output_tokens
  | None -> Alcotest.fail "expected usage"
;;

let test_finalize_no_usage () =
  let acc = Streaming.create_stream_acc () in
  let resp = finalize_ok acc in
  check_zero_usage resp.usage
;;

let test_finalize_unknown_content_type () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "unknown_type"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "data" });
  Streaming.accumulate_event
    acc
    (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    Alcotest.(check string)
      "reason"
      "unsupported_content_block_kind:unknown_type:index:0"
      reason;
    Alcotest.(check string) "raw omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected unknown content type to fail closed"
;;

let test_finalize_invalid_tool_json () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = Some "t1"
       ; tool_name = Some "tool"
       });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.InputJsonDelta "not json{" });
  Streaming.accumulate_event
    acc
    (Types.MessageDelta { stop_reason = Some Types.EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Types.Stream_parse_failed { reason; raw }) ->
    (* The offending tool-arg buffer is preserved in [raw] for keeper-log
       diagnosis (the Unknown_block/media arms still omit it). *)
    Alcotest.(check string) "raw preserved" "not json{" raw;
    Alcotest.(check bool)
      "malformed tool args"
      true
      (String.starts_with ~prefix:"malformed_tool_use_arguments:index:0" reason)
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected invalid tool JSON to fail closed"
;;

let test_finalize_multiple_blocks () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "first" });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 1; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 1; delta = Types.TextDelta "second" });
  let resp = finalize_ok acc in
  Alcotest.(check int) "two blocks" 2 (List.length resp.content)
;;

(* ── parse_sse_event re-export ────────────────────────────── *)

let test_parse_sse_event_text_delta () =
  let data =
    {|{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}|}
  in
  match Streaming.parse_sse_event (Some "content_block_delta") data with
  | Some (Types.ContentBlockDelta { index; delta = Types.TextDelta "hi" }) ->
    Alcotest.(check int) "index" 0 index
  | _ -> Alcotest.fail "expected ContentBlockDelta"
;;

let test_parse_sse_event_ping () =
  match Streaming.parse_sse_event (Some "ping") "{}" with
  | Some Types.Ping -> ()
  | _ -> Alcotest.fail "expected Ping"
;;

(* ── Suite ────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Streaming_cov"
    [ "stream_acc", [ Alcotest.test_case "create" `Quick test_create_stream_acc ]
    ; ( "accumulate"
      , [ Alcotest.test_case
            "message_start with usage"
            `Quick
            test_accumulate_message_start
        ; Alcotest.test_case
            "message_start no usage"
            `Quick
            test_accumulate_message_start_no_usage
        ; Alcotest.test_case "block_start text" `Quick test_accumulate_content_block_start
        ; Alcotest.test_case
            "block_start tool"
            `Quick
            test_accumulate_content_block_start_tool
        ; Alcotest.test_case "delta text" `Quick test_accumulate_content_block_delta_text
        ; Alcotest.test_case
            "delta thinking"
            `Quick
            test_accumulate_content_block_delta_thinking
        ; Alcotest.test_case "delta json" `Quick test_accumulate_content_block_delta_json
        ; Alcotest.test_case
            "delta new index"
            `Quick
            test_accumulate_content_block_delta_new_index
        ; Alcotest.test_case
            "message_delta with usage"
            `Quick
            test_accumulate_message_delta
        ; Alcotest.test_case
            "message_delta no usage"
            `Quick
            test_accumulate_message_delta_no_usage
        ; Alcotest.test_case "other events" `Quick test_accumulate_other_events
        ] )
    ; ( "finalize"
      , [ Alcotest.test_case "text only" `Quick test_finalize_text_only
        ; Alcotest.test_case "tool use" `Quick test_finalize_with_tool_use
        ; Alcotest.test_case "thinking" `Quick test_finalize_with_thinking
        ; Alcotest.test_case "with usage" `Quick test_finalize_with_usage
        ; Alcotest.test_case "no usage" `Quick test_finalize_no_usage
        ; Alcotest.test_case "unknown type" `Quick test_finalize_unknown_content_type
        ; Alcotest.test_case "invalid tool json" `Quick test_finalize_invalid_tool_json
        ; Alcotest.test_case "multiple blocks" `Quick test_finalize_multiple_blocks
        ] )
    ; ( "sse_re_export"
      , [ Alcotest.test_case "text delta" `Quick test_parse_sse_event_text_delta
        ; Alcotest.test_case "ping" `Quick test_parse_sse_event_ping
        ] )
    ]
;;
