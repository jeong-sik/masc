(** Additional coverage tests for Streaming module.

    Targets the stream accumulation logic (create_stream_acc,
    accumulate_event, finalize_stream_acc) and map_http_error which
    are not exercised by the existing test_streaming.ml. *)

open Agent_sdk
module Retry = Llm_provider.Retry
open Types

(* [lib/streaming.ml]'s stream-accumulator/map_http_error surface was a
   straight re-export of these two modules; call sites below still read
   [Streaming.*] against that combined surface directly. *)
module Streaming = struct
  include Llm_provider.Streaming
  include Llm_provider.Complete_stream_acc

  let map_http_error = Provider_failure_attribution.sdk_error_of_http_error
end

(* ── Helpers ────────────────────────────────────────────────────── *)

let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

let stream_error_to_string = function
  | Stream_provider_error { message; _ } -> message
  | Stream_parse_failed { reason; _ } -> reason
  | Stream_ndjson_parse_failed { reason; _ } -> reason
  | Stream_incomplete { reason } -> reason
  | Stream_unknown_event { event_type; _ } -> "unknown_event:" ^ event_type
  | Stream_unsupported_part { part; _ } -> "unsupported_part:" ^ part
  | Stream_unsupported_response { response; _ } -> "unsupported_response:" ^ response
;;

let fail_unexpected_stream_error err =
  Alcotest.fail ("unexpected SSE error: " ^ stream_error_to_string err)
;;

let check_zero_usage = function
  | Some u ->
    check_int "input" 0 u.input_tokens;
    check_int "output" 0 u.output_tokens;
    check_int "cache_creation" 0 u.cache_creation_input_tokens;
    check_int "cache_read" 0 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected zero usage"
;;

(** Unwrap finalize result or fail the test. *)
let finalize_ok acc =
  if not !(acc.Streaming.stop_reason_received)
  then
    Streaming.accumulate_event
      acc
      (MessageDelta { stop_reason = Some EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Ok resp -> resp
  | Error err -> fail_unexpected_stream_error err
;;

(* ── create_stream_acc + finalize empty ─────────────────────────── *)

let test_empty_acc_finalize () =
  let acc = Streaming.create_stream_acc () in
  let resp = finalize_ok acc in
  check_string "empty id" "" resp.id;
  check_string "empty model" "" resp.model;
  Alcotest.(check int) "no content" 0 (List.length resp.content);
  check_zero_usage resp.usage
;;

(* ── accumulate_event: MessageStart ─────────────────────────────── *)

let test_acc_message_start_with_usage () =
  let acc = Streaming.create_stream_acc () in
  let usage =
    Some
      { input_tokens = 100
      ; output_tokens = 0
      ; cache_creation_input_tokens = 25
      ; cache_read_input_tokens = 10
      ; cost_usd = None
      }
  in
  Streaming.accumulate_event
    acc
    (MessageStart { id = "msg_1"; model = "claude-test"; usage });
  let resp = finalize_ok acc in
  check_string "id" "msg_1" resp.id;
  check_string "model" "claude-test" resp.model;
  match resp.usage with
  | Some u ->
    check_int "input" 100 u.input_tokens;
    check_int "cache_creation" 25 u.cache_creation_input_tokens;
    check_int "cache_read" 10 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

let test_acc_message_start_no_usage () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageStart { id = "msg_2"; model = "test"; usage = None });
  let resp = finalize_ok acc in
  check_string "id" "msg_2" resp.id;
  check_zero_usage resp.usage
;;

(* ── accumulate_event: ContentBlockStart ────────────────────────── *)

let test_acc_content_block_start_text () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = TextDelta "hello " });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = TextDelta "world" });
  let resp = finalize_ok acc in
  match resp.content with
  | [ Text s ] -> check_string "text" "hello world" s
  | _ -> Alcotest.fail "expected single Text block"
;;

let test_acc_content_block_start_tool_use () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = Some "tu_1"
       ; tool_name = Some "calculator"
       });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = InputJsonDelta {|{"x": 42}|} });
  let resp = finalize_ok acc in
  match resp.content with
  | [ ToolUse { id; name; input } ] ->
    check_string "tool_id" "tu_1" id;
    check_string "tool_name" "calculator" name;
    let open Yojson.Safe.Util in
    check_int "input.x" 42 (input |> member "x" |> to_int)
  | _ -> Alcotest.fail "expected single ToolUse block"
;;

let test_acc_content_block_start_thinking () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = ThinkingDelta "let me think..." });
  let resp = finalize_ok acc in
  match resp.content with
  | [ Thinking { content; _ } ] ->
    check_string "thinking content" "let me think..." content
  | _ -> Alcotest.fail "expected single Thinking block"
;;

let test_acc_content_block_start_image () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "image"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta
       { index = 0
       ; delta =
           MediaDelta
             { media_type = "image/png"
             ; source_type = Types.Base64
             ; data = "iVBORw0KGgo="
             }
       });
  let resp = finalize_ok acc in
  match resp.content with
  | [ Image { media_type; source_type; data } ] ->
    check_string "media_type" "image/png" media_type;
    check_string "source_type" "base64" (Types.media_source_kind_to_string source_type);
    check_string "data" "iVBORw0KGgo=" data
  | _ -> Alcotest.fail "expected single Image block"
;;

(* ── accumulate_event: ContentBlockDelta for missing index ──────── *)

let test_acc_delta_creates_buffer_on_missing_index () =
  let acc = Streaming.create_stream_acc () in
  (* Delta arrives without a prior ContentBlockStart *)
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 5; delta = TextDelta "surprise" });
  (* The buffer should be created on demand.
     But without a block_type, finalize won't produce content for it.
     This tests the None branch of Hashtbl.find_opt in accumulate_event. *)
  let resp = finalize_ok acc in
  (* No block_type registered for index 5, so content stays empty *)
  check_int "no content (no block_type)" 0 (List.length resp.content)
;;

(* ── accumulate_event: MessageDelta ─────────────────────────────── *)

let test_acc_message_delta_stop_reason () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some StopToolUse; usage = None });
  check_bool "stop reason received" true !(acc.Streaming.stop_reason_received);
  (match !(acc.Streaming.stop_reason) with
   | StopToolUse -> ()
   | _ -> Alcotest.fail "expected accumulated StopToolUse");
  let resp = finalize_ok acc in
  (* Finalization reconciles a tool-stop with no tool blocks to the typed
     UnmatchedToolCalls outcome. *)
  match resp.stop_reason with
  | UnmatchedToolCalls -> ()
  | _ -> Alcotest.fail "expected reconciled UnmatchedToolCalls"
;;

let test_acc_message_delta_none_stop_reason () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event acc (MessageDelta { stop_reason = None; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_incomplete { reason = "stream_terminated_without_stop_reason" }) -> ()
  | Error _ -> Alcotest.fail "expected typed missing stop reason"
  | Ok _ -> Alcotest.fail "missing stop reason must not become EndTurn"
;;

let test_acc_message_delta_with_usage () =
  let acc = Streaming.create_stream_acc () in
  let usage =
    Some
      { input_tokens = 0
      ; output_tokens = 200
      ; cache_creation_input_tokens = 30
      ; cache_read_input_tokens = 15
      ; cost_usd = None
      }
  in
  Streaming.accumulate_event acc (MessageDelta { stop_reason = Some EndTurn; usage });
  let resp = finalize_ok acc in
  match resp.usage with
  | Some u ->
    check_int "output" 200 u.output_tokens;
    check_int "cache_creation" 30 u.cache_creation_input_tokens;
    check_int "cache_read" 15 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

let test_acc_message_delta_with_zero_cache () =
  let acc = Streaming.create_stream_acc () in
  let usage =
    Some
      { input_tokens = 0
      ; output_tokens = 100
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens = 0
      ; cost_usd = None
      }
  in
  Streaming.accumulate_event acc (MessageDelta { stop_reason = Some EndTurn; usage });
  let resp = finalize_ok acc in
  match resp.usage with
  | Some u ->
    (* Zero cache values should not overwrite prior values *)
    check_int "output" 100 u.output_tokens;
    check_int "cache_creation stays 0" 0 u.cache_creation_input_tokens;
    check_int "cache_read stays 0" 0 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

let test_acc_message_delta_none_usage () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  let resp = finalize_ok acc in
  check_zero_usage resp.usage
;;

(* ── accumulate_event: ignored events ───────────────────────────── *)

let test_acc_ignores_ping () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event acc Ping;
  let resp = finalize_ok acc in
  check_string "empty id" "" resp.id;
  check_int "no content" 0 (List.length resp.content)
;;

let test_acc_ignores_message_stop () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event acc MessageStop;
  let resp = finalize_ok acc in
  check_string "empty id" "" resp.id
;;

let test_acc_sse_error_propagated () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (SSEError { message = "overloaded"; error_type = None; raw = "overloaded" });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_provider_error { message; raw; _ }) ->
    check_string "error msg" "overloaded" message;
    check_string "raw" "overloaded" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected Error from SSEError"
;;

let test_acc_parse_failed_truncates_raw_chunk () =
  let acc = Streaming.create_stream_acc () in
  let raw = String.make 240 'x' in
  Streaming.accumulate_event acc (SSEParseFailed { raw; reason = "bad-json" });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw = got_raw }) ->
    check_string "reason" "bad-json" reason;
    check_int "raw preserved" 240 (String.length got_raw)
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected parse failure"
;;

let test_acc_unknown_event_truncates_raw_chunk () =
  let acc = Streaming.create_stream_acc () in
  let raw = String.make 240 'y' in
  Streaming.accumulate_event
    acc
    (SSEUnknownEventType { event_type = "future.event"; raw });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_unknown_event { event_type; raw = got_raw }) ->
    check_string "event_type" "future.event" event_type;
    check_int "raw preserved" 240 (String.length got_raw)
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected unknown event failure"
;;

let test_acc_ignores_content_block_stop () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event acc (ContentBlockStop { index = 0 });
  let resp = finalize_ok acc in
  check_int "no content" 0 (List.length resp.content)
;;

(* ── finalize: multi-block ordering ─────────────────────────────── *)

let test_finalize_multi_block_ordered () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageStart { id = "msg_m"; model = "claude"; usage = None });
  (* Block 2 registered before block 0 *)
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 2; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 2; delta = TextDelta "third" });
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = TextDelta "first" });
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 1; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 1; delta = TextDelta "second" });
  let resp = finalize_ok acc in
  check_int "3 blocks" 3 (List.length resp.content);
  match resp.content with
  | [ Text a; Text b; Text c ] ->
    check_string "block 0" "first" a;
    check_string "block 1" "second" b;
    check_string "block 2" "third" c
  | _ -> Alcotest.fail "expected 3 text blocks in order"
;;

(* ── finalize: tool_use with invalid JSON fails closed ─────────── *)

let test_finalize_tool_use_invalid_json () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = Some "tu_bad"
       ; tool_name = Some "broken"
       });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = InputJsonDelta "not valid json{{{" });
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    (* The offending tool-arg buffer is preserved in [raw] for keeper-log
       diagnosis (the Unknown_block/media arms still omit it). *)
    check_string "raw preserved" "not valid json{{{" raw;
    check_bool
      "malformed tool args"
      true
      (String.starts_with ~prefix:"malformed_tool_use_arguments:index:0" reason)
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected invalid tool_use JSON to fail closed"
;;

(* ── finalize: tool_use metadata boundary ───────────────────────── *)

let test_finalize_tool_use_missing_name () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = Some "tool-id-1"
       ; tool_name = None
       });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = InputJsonDelta {|{"ok": true}|} });
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    check_string "missing name reason" "malformed_tool_use:index:0:missing_name" reason;
    check_string "raw omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok response ->
    let (_ : api_response) = response in
    Alcotest.fail "expected missing tool name to fail closed"
;;

let test_finalize_tool_use_missing_id_fails_closed () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "tool_use"; tool_id = None; tool_name = Some "lookup" });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = InputJsonDelta {|{"ok": true}|} });
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some StopToolUse; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    check_string "missing id reason" "malformed_tool_use:index:0:missing_id" reason;
    check_string "raw omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected missing tool id to fail closed"
;;

(* ── finalize: text block with no delta (empty text) ────────────── *)

let test_finalize_text_block_no_delta () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  (* No delta events for this block *)
  let resp = finalize_ok acc in
  match resp.content with
  | [ Text s ] -> check_string "empty text" "" s
  | _ -> Alcotest.fail "expected empty Text block"
;;

(* ── finalize: unknown content_type fails closed ────────────────── *)

let test_finalize_unknown_content_type () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "unknown_future"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = TextDelta "ignored" });
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    check_string "reason" "unsupported_content_block_kind:unknown_future:index:0" reason;
    check_string "raw omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected unknown content type to fail closed"
;;

let test_finalize_registered_type_without_buffer () =
  let acc = Streaming.create_stream_acc () in
  Hashtbl.replace acc.block_types 7 "text";
  let resp = finalize_ok acc in
  match resp.content with
  | [ Text "" ] -> ()
  | _ -> Alcotest.fail "expected empty text from missing buffer"
;;

(* ── finalize: usage thresholds ─────────────────────────────────── *)

let test_finalize_usage_all_zero () =
  let acc = Streaming.create_stream_acc () in
  let resp = finalize_ok acc in
  check_zero_usage resp.usage
;;

let test_finalize_usage_only_cache_creation () =
  let acc = Streaming.create_stream_acc () in
  let usage =
    Some
      { input_tokens = 0
      ; output_tokens = 0
      ; cache_creation_input_tokens = 50
      ; cache_read_input_tokens = 0
      ; cost_usd = None
      }
  in
  Streaming.accumulate_event acc (MessageStart { id = "m"; model = "m"; usage });
  let resp = finalize_ok acc in
  match resp.usage with
  | Some u -> check_int "cache_creation" 50 u.cache_creation_input_tokens
  | None -> Alcotest.fail "expected usage with cache_creation only"
;;

let test_finalize_usage_only_cache_read () =
  let acc = Streaming.create_stream_acc () in
  let usage =
    Some
      { input_tokens = 0
      ; output_tokens = 0
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens = 20
      ; cost_usd = None
      }
  in
  Streaming.accumulate_event acc (MessageStart { id = "m"; model = "m"; usage });
  let resp = finalize_ok acc in
  match resp.usage with
  | Some u -> check_int "cache_read" 20 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage with cache_read only"
;;

(* ── Full sequence simulation ───────────────────────────────────── *)

let test_full_anthropic_sequence () =
  let acc = Streaming.create_stream_acc () in
  let events =
    [ MessageStart
        { id = "msg_full"
        ; model = "claude-sonnet-4"
        ; usage =
            Some
              { input_tokens = 50
              ; output_tokens = 0
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
        }
    ; ContentBlockStart
        { index = 0; content_type = "thinking"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = ThinkingDelta "analyzing..." }
    ; ContentBlockStop { index = 0 }
    ; ContentBlockStart
        { index = 1; content_type = "text"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 1; delta = TextDelta "The answer " }
    ; ContentBlockDelta { index = 1; delta = TextDelta "is 42." }
    ; ContentBlockStop { index = 1 }
    ; MessageDelta
        { stop_reason = Some EndTurn
        ; usage =
            Some
              { input_tokens = 0
              ; output_tokens = 30
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
        }
    ; MessageStop
    ]
  in
  List.iter (Streaming.accumulate_event acc) events;
  let resp = finalize_ok acc in
  check_string "id" "msg_full" resp.id;
  check_string "model" "claude-sonnet-4" resp.model;
  check_int "2 content blocks" 2 (List.length resp.content);
  (match resp.content with
   | [ Thinking { content; _ }; Text text ] ->
     check_string "thinking" "analyzing..." content;
     check_string "text" "The answer is 42." text
   | _ -> Alcotest.fail "expected Thinking + Text");
  (match resp.stop_reason with
   | EndTurn -> ()
   | _ -> Alcotest.fail "expected EndTurn");
  match resp.usage with
  | Some u ->
    check_int "input" 50 u.input_tokens;
    check_int "output" 30 u.output_tokens
  | None -> Alcotest.fail "expected usage"
;;

let test_full_tool_use_sequence () =
  let acc = Streaming.create_stream_acc () in
  let events =
    [ MessageStart
        { id = "msg_tu"
        ; model = "claude-sonnet-4"
        ; usage =
            Some
              { input_tokens = 80
              ; output_tokens = 0
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
        }
    ; ContentBlockStart
        { index = 0; content_type = "text"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = TextDelta "I'll use a tool." }
    ; ContentBlockStop { index = 0 }
    ; ContentBlockStart
        { index = 1
        ; content_type = "tool_use"
        ; tool_id = Some "tu_seq"
        ; tool_name = Some "calculator"
        }
    ; ContentBlockDelta { index = 1; delta = InputJsonDelta {|{"expression":"|} }
    ; ContentBlockDelta { index = 1; delta = InputJsonDelta {|2+2"}|} }
    ; ContentBlockStop { index = 1 }
    ; MessageDelta
        { stop_reason = Some StopToolUse
        ; usage =
            Some
              { input_tokens = 0
              ; output_tokens = 45
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
        }
    ; MessageStop
    ]
  in
  List.iter (Streaming.accumulate_event acc) events;
  let resp = finalize_ok acc in
  check_int "2 blocks" 2 (List.length resp.content);
  (match resp.content with
   | [ Text t; ToolUse { name; input; _ } ] ->
     check_string "text" "I'll use a tool." t;
     check_string "tool name" "calculator" name;
     let open Yojson.Safe.Util in
     check_string "expression" "2+2" (input |> member "expression" |> to_string)
   | _ -> Alcotest.fail "expected Text + ToolUse");
  match resp.stop_reason with
  | StopToolUse -> ()
  | _ -> Alcotest.fail "expected StopToolUse"
;;

(* ── map_http_error ─────────────────────────────────────────────── *)

let test_map_http_error_http_error () =
  let http_err =
    Llm_provider.Http_client.HttpError
      { code = 429; body = "rate limited"; retry_after_header = None }
  in
  let sdk_err = Streaming.map_http_error http_err in
  match sdk_err with
  | Error.Api _ -> ()
  | _ -> Alcotest.fail "expected Error.Api"
;;

let test_map_http_error_network_error () =
  let http_err =
    Llm_provider.Http_client.NetworkError
      { message = "connection refused"; kind = Unknown }
  in
  let sdk_err = Streaming.map_http_error http_err in
  match sdk_err with
  | Error.Api (Retry.NetworkError { message; _ }) ->
    check_string "message" "connection refused" message
  | _ -> Alcotest.fail "expected Error.Api NetworkError"
;;

let test_map_http_error_server_error () =
  let http_err =
    Llm_provider.Http_client.HttpError
      { code = 500
      ; body = {|{"error":{"message":"Internal server error"}}|}
      ; retry_after_header = None
      }
  in
  let sdk_err = Streaming.map_http_error http_err in
  match sdk_err with
  | Error.Api (Retry.ServerError { status; _ }) -> check_int "status" 500 status
  | _ -> Alcotest.fail "expected Error.Api ServerError"
;;

let test_map_http_error_auth_error () =
  let http_err =
    Llm_provider.Http_client.HttpError
      { code = 401; body = "unauthorized"; retry_after_header = None }
  in
  let sdk_err = Streaming.map_http_error http_err in
  match sdk_err with
  | Error.Api (Retry.AuthError _) -> ()
  | _ -> Alcotest.fail "expected Error.Api AuthError"
;;

let test_map_http_error_accept_rejected_not_network () =
  let http_err =
    Llm_provider.Http_client.AcceptRejected { reason = "missing transport" }
  in
  let sdk_err = Streaming.map_http_error http_err in
  match sdk_err with
  | Error.Api (Retry.InvalidRequest { message; _ }) ->
    check_string "message" "missing transport" message
  | _ -> Alcotest.fail "expected Error.Api InvalidRequest"
;;

let test_map_http_error_provider_parse_not_network () =
  let http_err =
    Llm_provider.Http_client.ProviderFailure
      { kind = Provider_parse_error { parser = Some "sse" }
      ; message = "SSE parse failed: bad json"
      }
  in
  let sdk_err = Streaming.map_http_error http_err in
  match sdk_err with
  | Error.Provider (Llm_provider.Error.ParseError _) -> ()
  | _ -> Alcotest.fail "expected Error.Provider ParseError"
;;

(* ── MessageDelta cache update with prior values ────────────────── *)

let test_acc_message_delta_cache_update_nonzero () =
  let acc = Streaming.create_stream_acc () in
  (* MessageStart sets initial cache values *)
  Streaming.accumulate_event
    acc
    (MessageStart
       { id = "m"
       ; model = "m"
       ; usage =
           Some
             { input_tokens = 50
             ; output_tokens = 0
             ; cache_creation_input_tokens = 10
             ; cache_read_input_tokens = 5
             ; cost_usd = None
             }
       });
  (* MessageDelta with nonzero cache values should update *)
  Streaming.accumulate_event
    acc
    (MessageDelta
       { stop_reason = Some EndTurn
       ; usage =
           Some
             { input_tokens = 0
             ; output_tokens = 100
             ; cache_creation_input_tokens = 20
             ; cache_read_input_tokens = 15
             ; cost_usd = None
             }
       });
  let resp = finalize_ok acc in
  match resp.usage with
  | Some u ->
    check_int "input" 50 u.input_tokens;
    check_int "output" 100 u.output_tokens;
    check_int "cache_creation added" 30 u.cache_creation_input_tokens;
    check_int "cache_read added" 20 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

(* ── accumulate multiple stop_reason overrides ──────────────────── *)

let test_acc_multiple_message_deltas () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some MaxTokens; usage = None });
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  let resp = finalize_ok acc in
  match resp.stop_reason with
  | EndTurn -> ()
  | _ -> Alcotest.fail "expected last stop_reason to win (EndTurn)"
;;

(* ── ContentBlockStart with tool_id=None, tool_name=Some ────────── *)

let test_acc_partial_tool_metadata () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = None
       ; tool_name = Some "partial"
       });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = InputJsonDelta {|{}|} });
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some StopToolUse; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    check_string "missing id reason" "malformed_tool_use:index:0:missing_id" reason;
    check_string "raw omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected partial tool metadata to fail closed"
;;

(* ── finalize: block with buffer but no text (empty buffer) ─────── *)

let test_finalize_thinking_empty_content () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  (* No delta -> empty thinking *)
  let resp = finalize_ok acc in
  match resp.content with
  | [ Thinking { content; _ } ] -> check_string "empty thinking" "" content
  | _ -> Alcotest.fail "expected empty Thinking block"
;;

let test_finalize_media_missing_metadata_fails () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "image"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = TextDelta "payload-without-metadata" });
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    check_string "error" "malformed_media_block:image:index:0" reason;
    check_string "raw omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected malformed media error"
;;

(* ── Suite ──────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "streaming_coverage"
    [ ( "create_stream_acc"
      , [ Alcotest.test_case "empty finalize" `Quick test_empty_acc_finalize ] )
    ; ( "accumulate_event"
      , [ Alcotest.test_case
            "message_start with usage"
            `Quick
            test_acc_message_start_with_usage
        ; Alcotest.test_case
            "message_start no usage"
            `Quick
            test_acc_message_start_no_usage
        ; Alcotest.test_case
            "content_block_start text"
            `Quick
            test_acc_content_block_start_text
        ; Alcotest.test_case
            "content_block_start tool_use"
            `Quick
            test_acc_content_block_start_tool_use
        ; Alcotest.test_case
            "content_block_start thinking"
            `Quick
            test_acc_content_block_start_thinking
        ; Alcotest.test_case
            "content_block_start image"
            `Quick
            test_acc_content_block_start_image
        ; Alcotest.test_case
            "delta missing index"
            `Quick
            test_acc_delta_creates_buffer_on_missing_index
        ; Alcotest.test_case
            "message_delta stop_reason"
            `Quick
            test_acc_message_delta_stop_reason
        ; Alcotest.test_case
            "message_delta none stop_reason"
            `Quick
            test_acc_message_delta_none_stop_reason
        ; Alcotest.test_case
            "message_delta with usage"
            `Quick
            test_acc_message_delta_with_usage
        ; Alcotest.test_case
            "message_delta zero cache"
            `Quick
            test_acc_message_delta_with_zero_cache
        ; Alcotest.test_case
            "message_delta none usage"
            `Quick
            test_acc_message_delta_none_usage
        ; Alcotest.test_case
            "message_delta cache update nonzero"
            `Quick
            test_acc_message_delta_cache_update_nonzero
        ; Alcotest.test_case
            "multiple message_deltas"
            `Quick
            test_acc_multiple_message_deltas
        ; Alcotest.test_case "partial tool metadata" `Quick test_acc_partial_tool_metadata
        ; Alcotest.test_case "ignores Ping" `Quick test_acc_ignores_ping
        ; Alcotest.test_case "ignores MessageStop" `Quick test_acc_ignores_message_stop
        ; Alcotest.test_case "SSEError propagated" `Quick test_acc_sse_error_propagated
        ; Alcotest.test_case
            "SSEParseFailed truncates"
            `Quick
            test_acc_parse_failed_truncates_raw_chunk
        ; Alcotest.test_case
            "SSEUnknownEventType truncates"
            `Quick
            test_acc_unknown_event_truncates_raw_chunk
        ; Alcotest.test_case
            "ignores ContentBlockStop"
            `Quick
            test_acc_ignores_content_block_stop
        ] )
    ; ( "finalize_stream_acc"
      , [ Alcotest.test_case
            "multi-block ordered"
            `Quick
            test_finalize_multi_block_ordered
        ; Alcotest.test_case
            "tool_use invalid JSON"
            `Quick
            test_finalize_tool_use_invalid_json
        ; Alcotest.test_case
            "tool_use missing name"
            `Quick
            test_finalize_tool_use_missing_name
        ; Alcotest.test_case
            "tool_use missing id fails closed"
            `Quick
            test_finalize_tool_use_missing_id_fails_closed
        ; Alcotest.test_case
            "text block no delta"
            `Quick
            test_finalize_text_block_no_delta
        ; Alcotest.test_case
            "unknown content_type"
            `Quick
            test_finalize_unknown_content_type
        ; Alcotest.test_case
            "registered type without buffer"
            `Quick
            test_finalize_registered_type_without_buffer
        ; Alcotest.test_case "usage all zero" `Quick test_finalize_usage_all_zero
        ; Alcotest.test_case
            "usage only cache_creation"
            `Quick
            test_finalize_usage_only_cache_creation
        ; Alcotest.test_case
            "usage only cache_read"
            `Quick
            test_finalize_usage_only_cache_read
        ; Alcotest.test_case
            "thinking empty content"
            `Quick
            test_finalize_thinking_empty_content
        ; Alcotest.test_case
            "media missing metadata"
            `Quick
            test_finalize_media_missing_metadata_fails
        ] )
    ; ( "full_sequence"
      , [ Alcotest.test_case "anthropic stream" `Quick test_full_anthropic_sequence
        ; Alcotest.test_case "tool_use stream" `Quick test_full_tool_use_sequence
        ] )
    ; ( "map_http_error"
      , [ Alcotest.test_case "http 429" `Quick test_map_http_error_http_error
        ; Alcotest.test_case "network error" `Quick test_map_http_error_network_error
        ; Alcotest.test_case "server 500" `Quick test_map_http_error_server_error
        ; Alcotest.test_case "auth 401" `Quick test_map_http_error_auth_error
        ; Alcotest.test_case
            "accept rejected is not network"
            `Quick
            test_map_http_error_accept_rejected_not_network
        ; Alcotest.test_case
            "provider parse is not network"
            `Quick
            test_map_http_error_provider_parse_not_network
        ] )
    ]
;;
