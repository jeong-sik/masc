(** Unit tests for Streaming.{create_stream_acc, accumulate_event, finalize_stream_acc}. *)

open Agent_core
module Retry = Llm_provider.Retry
open Types

(* [lib/streaming.ml]'s stream-accumulator/map_http_error surface was a
   straight re-export of these two modules; call sites below still read
   [Streaming.*] against that combined surface directly. *)
module Streaming = struct
  include Llm_provider.Streaming
  include Llm_provider.Complete_stream_acc

  let map_http_error = Provider_failure_attribution.core_error_of_http_error
end

(* ── Helpers ──────────────────────────────────────────────── *)

let make_usage ?(cache_create = 0) ?(cache_read = 0) inp out =
  { input_tokens = inp
  ; output_tokens = out
  ; cache_creation_input_tokens = cache_create
  ; cache_read_input_tokens = cache_read
  ; cost_usd = None
  }
;;

let acc_events acc events = List.iter (Streaming.accumulate_event acc) events

let stream_error_to_string = function
  | Stream_provider_error { message; _ } -> message
  | Stream_parse_failed { reason; _ } -> reason
  | Stream_ndjson_parse_failed { reason; _ } -> reason
  | Stream_incomplete { reason } -> reason
  | Stream_repeating { paragraph; _ } -> paragraph
  | Stream_unknown_event { event_type; _ } -> "unknown_event:" ^ event_type
  | Stream_unsupported_part { part; _ } -> "unsupported_part:" ^ part
  | Stream_unsupported_response { response; _ } -> "unsupported_response:" ^ response
;;

let finalize_with_end_turn acc =
  Streaming.accumulate_event
    acc
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Ok response -> response
  | Error err ->
    Alcotest.fail ("unexpected finalize error: " ^ stream_error_to_string err)
;;

let fail_unexpected_stream_error err =
  Alcotest.fail ("unexpected error: " ^ stream_error_to_string err)
;;

let check_zero_usage = function
  | Some u ->
    Alcotest.(check int) "input" 0 u.input_tokens;
    Alcotest.(check int) "output" 0 u.output_tokens;
    Alcotest.(check int) "cache_creation" 0 u.cache_creation_input_tokens;
    Alcotest.(check int) "cache_read" 0 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected zero usage"
;;

(* ── create_stream_acc ────────────────────────────────────── *)

let test_create_initial_state () =
  let acc = Streaming.create_stream_acc () in
  let response = finalize_with_end_turn acc in
  Alcotest.(check string) "msg_id empty" "" response.id;
  Alcotest.(check string) "msg_model empty" "" response.model;
  check_zero_usage response.usage
;;

(* ── accumulate: MessageStart ─────────────────────────────── *)

let test_accumulate_message_start () =
  let acc = Streaming.create_stream_acc () in
  let evt =
    MessageStart
      { id = "msg_123"; model = "claude-sonnet-4"; usage = Some (make_usage 100 0) }
  in
  Streaming.accumulate_event acc evt;
  let response = finalize_with_end_turn acc in
  Alcotest.(check string) "id set" "msg_123" response.id;
  Alcotest.(check string) "model set" "claude-sonnet-4" response.model;
  match response.usage with
  | Some usage -> Alcotest.(check int) "input_tokens" 100 usage.input_tokens
  | None -> Alcotest.fail "expected usage"
;;

let test_accumulate_message_start_no_usage () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageStart { id = "m1"; model = "test"; usage = None });
  let response = finalize_with_end_turn acc in
  Alcotest.(check string) "id" "m1" response.id;
  check_zero_usage response.usage
;;

let test_accumulate_message_start_with_cache () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageStart
       { id = "m2"
       ; model = "test"
       ; usage = Some (make_usage ~cache_create:50 ~cache_read:30 200 0)
       });
  let response = finalize_with_end_turn acc in
  match response.usage with
  | Some usage ->
    Alcotest.(check int) "cache_creation" 50 usage.cache_creation_input_tokens;
    Alcotest.(check int) "cache_read" 30 usage.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

(* ── accumulate: ContentBlockStart ────────────────────────── *)

let test_accumulate_content_block_start_text () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ Text "" ] -> ()
  | _ -> Alcotest.fail "expected an announced empty text block"
;;

let test_accumulate_content_block_start_tool () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 1
       ; content_type = "tool_use"
       ; tool_id = Some "tu_1"
       ; tool_name = Some "calculator"
       });
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ ToolUse { id; name; input = `Assoc [] } ] ->
    Alcotest.(check string) "tool_id" "tu_1" id;
    Alcotest.(check string) "tool_name" "calculator" name
  | _ -> Alcotest.fail "expected typed tool block"
;;

(* ── accumulate: repeating generation ─────────────────────── *)

(* Measured on a live collapse: 29,788 bytes, 234 paragraphs, 11 distinct, and
   the third occurrence of a repeated paragraph landed at 1,691 bytes — 5% of
   what the provider was eventually paid for. The stream ends at that third
   occurrence instead of at the token ceiling. *)

let long_paragraph =
  "lesson 03:20:12Z를 다시 정확히 읽자: due 전 금지는 dashboard 보고에만 적용된다"
;;

let feed_paragraphs acc lines =
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  List.iter
    (fun line ->
       Streaming.accumulate_event
         acc
         (ContentBlockDelta { index = 0; delta = TextDelta (line ^ "\n") }))
    lines
;;

let test_repeating_paragraph_ends_the_stream () =
  let acc = Streaming.create_stream_acc () in
  feed_paragraphs acc [ long_paragraph; "다른 문단이 사이에 하나 들어간다 " ^ long_paragraph; long_paragraph; long_paragraph ];
  match Streaming.failure acc with
  | Some (Stream_repeating { paragraph; occurrences; bytes_seen }) ->
    Alcotest.(check string) "the repeated paragraph" long_paragraph paragraph;
    Alcotest.(check int) "stopped at the threshold" 3 occurrences;
    if bytes_seen <= 0 then Alcotest.fail "bytes_seen must record what was read"
  | Some _ -> Alcotest.fail "a repeat must not be reported as another failure"
  | None -> Alcotest.fail "three identical paragraphs must end the stream"
;;

let test_two_occurrences_do_not_end_the_stream () =
  let acc = Streaming.create_stream_acc () in
  feed_paragraphs acc [ long_paragraph; long_paragraph ];
  match Streaming.failure acc with
  | None -> ()
  | Some _ -> Alcotest.fail "two occurrences are repetition, not a collapse"
;;

(* Prose repeats short strings all the time — list markers, table cells, a
   bare "ok". Only paragraph-sized units count, or ordinary answers would be
   cut off. *)
let test_short_repeated_lines_are_left_alone () =
  let acc = Streaming.create_stream_acc () in
  feed_paragraphs acc [ "- ok"; "- ok"; "- ok"; "- ok"; "- ok" ];
  match Streaming.failure acc with
  | None -> ()
  | Some _ -> Alcotest.fail "short repeated lines must not end a stream"
;;

(* A reasoning block that circles is a separate question with its own ceiling;
   stopping a provider mid-thought would end turns that were about to answer. *)
let test_thinking_repeats_are_not_guarded () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  List.iter
    (fun _ ->
       Streaming.accumulate_event
         acc
         (ContentBlockDelta { index = 0; delta = ThinkingDelta (long_paragraph ^ "\n") }))
    [ (); (); (); () ];
  match Streaming.failure acc with
  | None -> ()
  | Some _ -> Alcotest.fail "a repeating thinking block is not this guard's business"
;;

(* ── accumulate: ContentBlockDelta ────────────────────────── *)

let test_accumulate_text_deltas () =
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
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ Text text ] -> Alcotest.(check string) "concatenated" "hello world" text
  | _ -> Alcotest.fail "expected text block"
;;

let test_accumulate_delta_without_start () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 5; delta = TextDelta "orphan" });
  match Streaming.finalize_stream_acc acc with
  | Error
      (Stream_parse_failed
         { reason = "content_block_delta_without_start:index:5"; raw = "" }) -> ()
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "unannounced delta must fail before projection"
;;

let test_repeated_text_deltas_append () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  let resolve text =
    Streaming.resolve_event acc (ContentBlockDelta { index = 0; delta = TextDelta text })
  in
  (match resolve "a" with
   | Stream_event_accepted
       (ContentBlockDelta { delta = TextDelta "a"; _ }) -> ()
   | _ -> Alcotest.fail "first incremental text delta was not accepted exactly");
  (match resolve "a" with
   | Stream_event_accepted
       (ContentBlockDelta { delta = TextDelta "a"; _ }) -> ()
   | _ -> Alcotest.fail "repeated incremental text delta was not appended");
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ Text "aa" ] -> ()
  | _ -> Alcotest.fail "repeated incremental text was lost"
;;

let test_text_snapshot_resolution_is_canonical () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event acc
    (ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  Streaming.accumulate_event acc
    (ContentBlockDelta { index = 0; delta = TextDelta "ha" });
  (match
     Streaming.resolve_event acc
       (ContentBlockDelta { index = 0; delta = TextSnapshot "haha" })
   with
   | Stream_event_accepted
       (ContentBlockDelta { delta = TextDelta "ha"; _ }) -> ()
   | _ -> Alcotest.fail "typed text snapshot was not reduced to its unseen suffix");
  (match
     Streaming.resolve_event acc
       (ContentBlockDelta { index = 0; delta = TextSnapshot "haha" })
   with
   | Stream_event_suppressed -> ()
   | _ -> Alcotest.fail "exact typed text snapshot replay was not suppressed");
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ Text "haha" ] -> ()
  | _ -> Alcotest.fail "typed snapshot callbacks diverged from canonical response"
;;

let test_text_snapshot_conflict_fails_closed () =
  let acc = Streaming.create_stream_acc () in
  acc_events acc
    [ ContentBlockStart
        { index = 0; content_type = "text"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = TextDelta "abc" }
    ];
  match
    Streaming.resolve_event acc
      (ContentBlockDelta { index = 0; delta = TextSnapshot "ax" })
  with
  | Stream_event_rejected
      (Stream_parse_failed { reason = "text_snapshot_conflict:index:0"; raw = "" }) -> ()
  | _ -> Alcotest.fail "conflicting typed text snapshot did not fail closed"
;;

let test_incremental_text_deltas_remain_incremental () =
  let acc = Streaming.create_stream_acc () in
  acc_events acc
    [ ContentBlockStart
        { index = 0; content_type = "text"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = TextDelta "Hel" }
    ; ContentBlockDelta { index = 0; delta = TextDelta "lo" }
    ];
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ Text "Hello" ] -> ()
  | _ -> Alcotest.fail "incremental text deltas changed meaning"
;;

let test_accumulate_thinking_delta () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = ThinkingDelta "I think" });
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ Thinking { content; _ } ] ->
    Alcotest.(check string) "thinking text" "I think" content
  | _ -> Alcotest.fail "expected thinking block"
;;

let test_accumulate_thinking_signature_delta () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0; content_type = "thinking"; tool_id = None; tool_name = None });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = ThinkingSignatureDelta "sig_opaque" });
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ Thinking { signature = Some signature; _ } ] ->
    Alcotest.(check string) "signature" "sig_opaque" signature
  | _ -> Alcotest.fail "expected signed thinking block"
;;

let test_accumulate_input_json_delta () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (ContentBlockStart
       { index = 0
       ; content_type = "tool_use"
       ; tool_id = Some "t1"
       ; tool_name = Some "calc"
       });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = InputJsonDelta "{\"x\":" });
  Streaming.accumulate_event
    acc
    (ContentBlockDelta { index = 0; delta = InputJsonDelta "42}" });
  let response = finalize_with_end_turn acc in
  match response.content with
  | [ ToolUse { input; _ } ] ->
    Alcotest.(check string) "json assembled" "{\"x\":42}" (Yojson.Safe.to_string input)
  | _ -> Alcotest.fail "expected tool block"
;;

(* ── accumulate: MessageDelta ─────────────────────────────── *)

let test_accumulate_message_delta () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageDelta
       { stop_reason = Some EndTurn
       ; usage =
           (* The classic wire shape: the final delta reports only the
              cumulative output counter. *)
           Some
             { Types.input_tokens = None
             ; output_tokens = Some 75
             ; cache_creation_input_tokens = None
             ; cache_read_input_tokens = None
             }
       });
  match Streaming.finalize_stream_acc acc with
  | Ok { stop_reason = EndTurn; usage = Some usage; _ } ->
    Alcotest.(check int) "output_tokens" 75 usage.output_tokens
  | Ok _ -> Alcotest.fail "expected EndTurn with usage"
  | Error err ->
    Alcotest.fail ("unexpected finalize error: " ^ stream_error_to_string err)
;;

let test_accumulate_message_delta_no_stop () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event acc (MessageDelta { stop_reason = None; usage = None });
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_incomplete { reason = "stream_terminated_without_stop_reason" }) -> ()
  | Error _ -> Alcotest.fail "expected typed missing stop reason"
  | Ok _ -> Alcotest.fail "missing stop reason must not default to EndTurn"
;;

let test_accumulate_message_delta_cache_update () =
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event
    acc
    (MessageDelta
       { stop_reason = Some EndTurn
       ; usage =
           Some
             { Types.input_tokens = None
             ; output_tokens = Some 50
             ; cache_creation_input_tokens = Some 25
             ; cache_read_input_tokens = Some 10
             }
       });
  match Streaming.finalize_stream_acc acc with
  | Ok { usage = Some usage; _ } ->
    Alcotest.(check int) "cache_creation updated" 25 usage.cache_creation_input_tokens;
    Alcotest.(check int) "cache_read updated" 10 usage.cache_read_input_tokens
  | Ok _ -> Alcotest.fail "expected usage"
  | Error err ->
    Alcotest.fail ("unexpected finalize error: " ^ stream_error_to_string err)
;;

(* ── accumulate: ignored events ───────────────────────────── *)

let test_accumulate_ignores_ping () =
  let acc = Streaming.create_stream_acc () in
  Alcotest.(check bool) "fresh stream has not failed" false (Streaming.stream_failed acc);
  Streaming.accumulate_event acc Ping;
  Streaming.accumulate_event
    acc
    (SSEError { message = "oops"; error_type = None; raw = "oops" });
  Streaming.accumulate_event acc MessageStop;
  Streaming.accumulate_event acc (ContentBlockStop { index = 0 });
  Alcotest.(check bool)
    "typed stream failure is terminal"
    true
    (Streaming.stream_failed acc);
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_provider_error { message = "oops"; _ }) -> ()
  | Error _ -> Alcotest.fail "expected provider error"
  | Ok _ -> Alcotest.fail "failed stream must not finalize successfully"
;;

(* ── finalize_stream_acc ──────────────────────────────────── *)

let test_finalize_text_response () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "msg_f"; model = "test"; usage = Some (make_usage 100 0) }
    ; ContentBlockStart
        { index = 0; content_type = "text"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = TextDelta "hello world" }
    ; MessageDelta
        { stop_reason = Some EndTurn
        ; usage =
            Some
              { Types.input_tokens = None
              ; output_tokens = Some 50
              ; cache_creation_input_tokens = None
              ; cache_read_input_tokens = None
              }
        }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error err -> fail_unexpected_stream_error err
  | Ok resp ->
    Alcotest.(check string) "id" "msg_f" resp.id;
    Alcotest.(check string) "model" "test" resp.model;
    (match resp.stop_reason with
     | EndTurn -> ()
     | _ -> Alcotest.fail "expected EndTurn");
    Alcotest.(check int) "1 content block" 1 (List.length resp.content);
    (match List.hd resp.content with
     | Text s -> Alcotest.(check string) "text" "hello world" s
     | _ -> Alcotest.fail "expected Text");
    (match resp.usage with
     | Some u ->
       Alcotest.(check int) "input" 100 u.input_tokens;
       Alcotest.(check int) "output" 50 u.output_tokens
     | None -> Alcotest.fail "expected usage")
;;

let test_finalize_thinking_block () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0; content_type = "thinking"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = ThinkingDelta "reasoning here" }
    ; MessageDelta { stop_reason = Some EndTurn; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error err -> fail_unexpected_stream_error err
  | Ok resp ->
    (match List.hd resp.content with
     | Thinking { content; _ } ->
       Alcotest.(check string) "thinking" "reasoning here" content
     | _ -> Alcotest.fail "expected Thinking")
;;

let test_finalize_thinking_signature_block () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0; content_type = "thinking"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = ThinkingDelta "" }
    ; ContentBlockDelta { index = 0; delta = ThinkingSignatureDelta "sig_opaque" }
    ; MessageDelta { stop_reason = Some EndTurn; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error err -> fail_unexpected_stream_error err
  | Ok resp ->
    (match List.hd resp.content with
     | Thinking { signature; content } ->
       Alcotest.(check bool) "signature" true (signature = Some "sig_opaque");
       Alcotest.(check string) "omitted thinking text" "" content
     | _ -> Alcotest.fail "expected Thinking")
;;

let test_finalize_redacted_thinking_block () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0
        ; content_type = "redacted_thinking"
        ; tool_id = Some "opaque_data"
        ; tool_name = None
        }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error err -> fail_unexpected_stream_error err
  | Ok resp ->
    (match List.hd resp.content with
     | RedactedThinking data -> Alcotest.(check string) "data" "opaque_data" data
     | _ -> Alcotest.fail "expected RedactedThinking")
;;

let test_finalize_tool_use () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu_1"
        ; tool_name = Some "calc"
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "{\"x\":42}" }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error err -> fail_unexpected_stream_error err
  | Ok resp ->
    (match List.hd resp.content with
     | ToolUse { id; name; input } ->
       Alcotest.(check string) "tool_id" "tu_1" id;
       Alcotest.(check string) "tool_name" "calc" name;
       Alcotest.(check string) "input" "{\"x\":42}" (Yojson.Safe.to_string input)
     | _ -> Alcotest.fail "expected ToolUse")
;;

let test_duplicate_tool_start_before_payload_is_idempotent () =
  let acc = Streaming.create_stream_acc () in
  let start =
    ContentBlockStart
      { index = 0
      ; content_type = "tool_use"
      ; tool_id = Some "tu-replayed"
      ; tool_name = Some "Read"
      }
  in
  acc_events acc
    [ start
    ; start
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "{\"path\":" }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "\"a.ml\"}" }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error err -> fail_unexpected_stream_error err
  | Ok response ->
    (match response.content with
     | [ ToolUse { input; _ } ] ->
       Alcotest.(check string)
         "empty duplicate header is idempotent"
         "{\"path\":\"a.ml\"}"
         (Yojson.Safe.to_string input)
     | _ -> Alcotest.fail "expected one ToolUse")
;;

let test_duplicate_tool_start_after_payload_fails_closed () =
  let acc = Streaming.create_stream_acc () in
  let start =
    ContentBlockStart
      { index = 0
      ; content_type = "tool_use"
      ; tool_id = Some "tu-ambiguous"
      ; tool_name = Some "Read"
      }
  in
  acc_events acc
    [ start
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "{\"path\":" }
    ; start
    ];
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    Alcotest.(check string)
      "typed ambiguous replay"
      "content_block_start_after_payload:index:0"
      reason;
    Alcotest.(check string) "provider payload omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "a repeated tool header after payload must fail closed"
;;

let test_conflicting_tool_start_fails_closed () =
  let acc = Streaming.create_stream_acc () in
  acc_events acc
    [ ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu-first"
        ; tool_name = Some "Read"
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "{}" }
    ; ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu-second"
        ; tool_name = Some "Write"
        }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    Alcotest.(check string) "typed conflict" "content_block_start_conflict:index:0" reason;
    Alcotest.(check string) "provider payload omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "conflicting block start must fail closed"
;;

let test_tool_use_rejects_non_input_delta_kinds () =
  let deltas =
    [ "text", TextDelta "not args"
    ; "thinking", ThinkingDelta "not args"
    ; ( "reasoning"
      , ReasoningDetailsDelta { reasoning_content = Some "not args"; details = [] } )
    ; ( "media"
      , MediaDelta
          { media_type = "image/png"; source_type = Base64; data = "not args" } )
    ; "thinking signature", ThinkingSignatureDelta "not args"
    ]
  in
  List.iter
    (fun (label, delta) ->
       let acc = Streaming.create_stream_acc () in
       acc_events acc
         [ ContentBlockStart
             { index = 3
             ; content_type = "tool_use"
             ; tool_id = Some "tu-kind"
             ; tool_name = Some "Read"
             }
         ; ContentBlockDelta { index = 3; delta }
         ];
       match Streaming.finalize_stream_acc acc with
       | Error (Stream_parse_failed { reason; raw }) ->
         let expected =
           "content_block_delta_kind_mismatch:index:3:block:tool_use:delta:"
           ^ (match label with
              | "text" -> "text"
              | "thinking" -> "thinking"
              | "reasoning" -> "reasoning_details"
              | "media" -> "media"
              | "thinking signature" -> "thinking_signature"
              | _ -> assert false)
         in
         Alcotest.(check string)
           (label ^ " mismatch")
           expected
           reason;
         Alcotest.(check string) (label ^ " raw omitted") "" raw
       | Error err -> fail_unexpected_stream_error err
       | Ok _ -> Alcotest.fail (label ^ " delta must not become tool input"))
    deltas
;;

let test_tool_use_rejects_delta_after_stop () =
  let terminal_events =
    [ "content block stop", ContentBlockStop { index = 0 }
    ; "message stop", MessageStop
    ]
  in
  List.iter
    (fun (label, terminal) ->
       let acc = Streaming.create_stream_acc () in
       acc_events acc
         [ ContentBlockStart
             { index = 0
             ; content_type = "tool_use"
             ; tool_id = Some "tu-late"
             ; tool_name = Some "Read"
             }
         ; ContentBlockDelta { index = 0; delta = InputJsonSnapshot "{}" }
         ; terminal
         ; ContentBlockDelta
             { index = 0; delta = InputJsonSnapshot "{\"late\":true}" }
         ];
       match Streaming.finalize_stream_acc acc with
       | Error (Stream_parse_failed { reason; raw }) ->
         let expected_reason =
           match label with
           | "content block stop" -> "content_block_delta_after_stop:index:0"
           | "message stop" -> "content_block_delta_after_terminal"
           | _ -> assert false
         in
         Alcotest.(check string)
           (label ^ " closes input")
           expected_reason
           reason;
         Alcotest.(check string) (label ^ " raw omitted") "" raw
       | Error err -> fail_unexpected_stream_error err
       | Ok _ -> Alcotest.fail (label ^ " must freeze the tool input"))
    terminal_events
;;

let test_conflicting_message_start_fails_closed () =
  let acc = Streaming.create_stream_acc () in
  acc_events acc
    [ MessageStart { id = "message-a"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu-message"
        ; tool_name = Some "Read"
        }
    ; MessageStart { id = "message-b"; model = "m"; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    Alcotest.(check string) "typed message conflict" "message_start_conflict" reason;
    Alcotest.(check string) "provider payload omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "different MessageStart must not inherit open blocks"
;;

let expect_parse_failure expected events =
  let acc = Streaming.create_stream_acc () in
  acc_events acc events;
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    Alcotest.(check string) "typed parse failure" expected reason;
    Alcotest.(check string) "provider payload omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail (expected ^ " was accepted")
;;

let test_message_start_replay_requires_exact_metadata () =
  let usage = make_usage 10 1 in
  expect_parse_failure "message_start_conflict"
    [ MessageStart { id = "same"; model = "model-a"; usage = Some usage }
    ; MessageStart { id = "same"; model = "model-b"; usage = Some usage }
    ];
  expect_parse_failure "message_start_conflict"
    [ MessageStart { id = ""; model = "model-a"; usage = Some usage }
    ; MessageStart
        { id = ""; model = "model-a"; usage = Some (make_usage 10 2) }
    ]
;;

let test_terminal_state_is_write_once () =
  expect_parse_failure "content_block_start_after_terminal"
    [ MessageDelta { stop_reason = Some EndTurn; usage = None }
    ; ContentBlockStart
        { index = 1
        ; content_type = "tool_use"
        ; tool_id = Some "late-tool"
        ; tool_name = Some "Read"
        }
    ];
  expect_parse_failure "stop_reason_conflict"
    [ MessageDelta { stop_reason = Some EndTurn; usage = None }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ];
  expect_parse_failure "content_block_start_after_terminal"
    [ MessageStop
    ; ContentBlockStart
        { index = 2
        ; content_type = "tool_use"
        ; tool_id = Some "after-stop"
        ; tool_name = Some "Read"
        }
    ]
;;

let test_tool_start_requires_complete_identity () =
  expect_parse_failure "malformed_tool_use:index:0:missing_identity"
    [ ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = None
        ; tool_name = Some "Read"
        }
    ]
;;

let test_content_kind_and_delta_kind_must_match () =
  let fixtures =
    [ ( "image text"
      , ContentBlockStart
          { index = 0; content_type = "image"; tool_id = None; tool_name = None }
      , TextDelta "visible-before-finalize"
      , "content_block_delta_kind_mismatch:index:0:block:image:delta:text" )
    ; ( "text input"
      , ContentBlockStart
          { index = 0; content_type = "text"; tool_id = None; tool_name = None }
      , InputJsonSnapshot "{}"
      , "content_block_delta_kind_mismatch:index:0:block:text:delta:input_json_snapshot" )
    ]
  in
  List.iter
    (fun (label, start, delta, expected) ->
       let acc = Streaming.create_stream_acc () in
       Streaming.accumulate_event acc start;
       (match
          Streaming.resolve_event acc (ContentBlockDelta { index = 0; delta })
        with
        | Stream_event_rejected
            (Stream_parse_failed { reason; raw = "" }) ->
          Alcotest.(check string) label expected reason
        | _ -> Alcotest.fail (label ^ " mismatch escaped canonical validation")))
    fixtures
;;

let test_unknown_content_kind_is_rejected_at_start () =
  let acc = Streaming.create_stream_acc () in
  match
    Streaming.resolve_event acc
      (ContentBlockStart
         { index = 7; content_type = "future_kind"; tool_id = None; tool_name = None })
  with
  | Stream_event_rejected
      (Stream_parse_failed
         { reason = "unsupported_content_block_kind:future_kind:index:7"; raw = "" }) -> ()
  | _ -> Alcotest.fail "unknown block start escaped canonical validation"
;;

let test_media_metadata_is_frozen_by_first_delta () =
  let accepted = Streaming.create_stream_acc () in
  acc_events accepted
    [ ContentBlockStart
        { index = 1; content_type = "image"; tool_id = None; tool_name = None }
    ; ContentBlockDelta
        { index = 1
        ; delta =
            MediaDelta { media_type = "image/png"; source_type = Base64; data = "a" }
        }
    ; ContentBlockDelta
        { index = 1
        ; delta =
            MediaDelta { media_type = "image/png"; source_type = Base64; data = "b" }
        }
    ];
  let accepted_response = finalize_with_end_turn accepted in
  (match accepted_response.content with
   | [ Image { media_type = "image/png"; source_type = Base64; data = "ab" } ] -> ()
   | _ -> Alcotest.fail "matching media chunks did not assemble canonically");
  let acc = Streaming.create_stream_acc () in
  Streaming.accumulate_event acc
    (ContentBlockStart
       { index = 2; content_type = "image"; tool_id = None; tool_name = None });
  Streaming.accumulate_event acc
    (ContentBlockDelta
       { index = 2
       ; delta = MediaDelta { media_type = "image/png"; source_type = Base64; data = "a" }
       });
  (match
     Streaming.resolve_event acc
       (ContentBlockDelta
          { index = 2
          ; delta =
              MediaDelta
                { media_type = "image/jpeg"; source_type = Base64; data = "b" }
          })
   with
   | Stream_event_rejected
       (Stream_parse_failed
          { reason = "media_delta_metadata_conflict:index:2"; raw = "" }) -> ()
   | _ -> Alcotest.fail "media metadata drift escaped canonical validation")
;;

let test_finalize_tool_use_invalid_json () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0
        ; content_type = "tool_use"
        ; tool_id = Some "tu_2"
        ; tool_name = Some "bad"
        }
    ; ContentBlockDelta { index = 0; delta = InputJsonDelta "not json{" }
    ; MessageDelta { stop_reason = Some EndTurn; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    (* The offending tool-arg buffer is preserved in [raw] for keeper-log
       diagnosis; structural failures intentionally omit provider payloads. *)
    Alcotest.(check string) "raw preserved" "not json{" raw;
    Alcotest.(check bool)
      "malformed tool args"
      true
      (String.starts_with ~prefix:"malformed_tool_use_arguments:index:0" reason)
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected malformed tool_use arguments to fail closed"
;;

let test_finalize_tool_use_invalid_json_preserves_assembly_boundaries () =
  let acc = Streaming.create_stream_acc () in
  let first = {|{"argv":["python3","-c","print(1)"|} in
  let second = {|,"cwd":"repos/masc"}|} in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "glm-5.3"; usage = None }
    ; ContentBlockStart
        { index = 2
        ; content_type = "tool_use"
        ; tool_id = Some "call_live_shape"
        ; tool_name = Some "Execute"
        }
    ; ContentBlockDelta { index = 2; delta = InputJsonDelta first }
    ; ContentBlockDelta { index = 2; delta = InputJsonDelta second }
    ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    Alcotest.(check string) "raw remains exact" (first ^ second) raw;
    Alcotest.(check bool)
      "delta byte boundaries retained"
      true
      (String.ends_with
         ~suffix:
           (Printf.sprintf
              ":assembly=delta:%d,delta:%d"
              (String.length first)
              (String.length second))
         reason)
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected malformed assembled arguments to fail closed"
;;

let test_finalize_tool_use_rejects_non_object_json () =
  List.iter
    (fun (label, raw) ->
       let acc = Streaming.create_stream_acc () in
       acc_events
         acc
         [ MessageStart { id = "m"; model = "m"; usage = None }
         ; ContentBlockStart
             { index = 0
             ; content_type = "tool_use"
             ; tool_id = Some "tu-non-object"
             ; tool_name = Some "lookup"
             }
         ; ContentBlockDelta { index = 0; delta = InputJsonDelta raw }
         ; MessageDelta { stop_reason = Some StopToolUse; usage = None }
         ];
       match Streaming.finalize_stream_acc acc with
       | Error (Stream_parse_failed { reason; raw = observed_raw }) ->
         Alcotest.(check string) (label ^ " raw") raw observed_raw;
         Alcotest.(check string)
           (label ^ " reason")
           "malformed_tool_use_arguments:index:0:not_object"
           reason
       | Error err -> fail_unexpected_stream_error err
       | Ok _ -> Alcotest.fail (label ^ " tool input must fail closed"))
    [ "number", "42"
    ; "array", "[]"
    ; "boolean", "true"
    ; "null", "null"
    ; "string", {|"value"|}
    ]
;;

let test_finalize_multi_block_ordering () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0; content_type = "thinking"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = ThinkingDelta "think" }
    ; ContentBlockStart
        { index = 1; content_type = "text"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 1; delta = TextDelta "answer" }
    ; MessageDelta { stop_reason = Some EndTurn; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error err -> fail_unexpected_stream_error err
  | Ok resp ->
    Alcotest.(check int) "2 blocks" 2 (List.length resp.content);
    (match resp.content with
     | [ Thinking _; Text "answer" ] -> ()
     | _ -> Alcotest.fail "expected [Thinking; Text] in order")
;;

let test_finalize_no_usage () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0; content_type = "text"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = TextDelta "x" }
    ; MessageDelta { stop_reason = Some EndTurn; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error err -> fail_unexpected_stream_error err
  | Ok resp -> check_zero_usage resp.usage
;;

let test_finalize_unknown_block_type_fails_closed () =
  let acc = Streaming.create_stream_acc () in
  acc_events
    acc
    [ MessageStart { id = "m"; model = "m"; usage = None }
    ; ContentBlockStart
        { index = 0; content_type = "future_type"; tool_id = None; tool_name = None }
    ; ContentBlockDelta { index = 0; delta = TextDelta "data" }
    ; MessageDelta { stop_reason = Some EndTurn; usage = None }
    ];
  match Streaming.finalize_stream_acc acc with
  | Error (Stream_parse_failed { reason; raw }) ->
    Alcotest.(check string)
      "reason"
      "unsupported_content_block_kind:future_type:index:0"
      reason;
    Alcotest.(check string) "raw omitted" "" raw
  | Error err -> fail_unexpected_stream_error err
  | Ok _ -> Alcotest.fail "expected unknown content block kind to fail closed"
;;

(* ── map_http_error ───────────────────────────────────────── *)

let test_map_http_error_http () =
  let err =
    Streaming.map_http_error
      (Llm_provider.Http_client.HttpError
         { code = 429; body = "rate limited"; retry_after_header = None })
  in
  match err with
  | Error.Api (Retry.RateLimited _) -> ()
  | _ -> Alcotest.fail "expected RateLimited"
;;

let test_map_http_error_network () =
  let err =
    Streaming.map_http_error
      (Llm_provider.Http_client.NetworkError
         { message = "connection refused"; kind = Unknown })
  in
  match err with
  | Error.Api (Retry.NetworkError { message; _ }) ->
    Alcotest.(check string) "msg" "connection refused" message
  | _ -> Alcotest.fail "expected NetworkError"
;;

let test_map_http_error_provider_parse_failure () =
  let err =
    Streaming.map_http_error
      (Llm_provider.Http_client.ProviderFailure
         { kind = Provider_parse_error { parser = Some "sse" }
         ; message = "SSE parse failed: bad json"
         })
  in
  match err with
  | Error.Provider (Llm_provider.Error.ParseError { detail }) ->
    Alcotest.(check bool) "detail mentions sse parser" true (String.contains detail 's')
  | _ -> Alcotest.fail "expected provider ParseError"
;;

let test_map_http_error_empty_completion_maps_to_unavailable () =
  List.iter
    (fun expected ->
       let err =
         Streaming.map_http_error
           (Llm_provider.Http_client.empty_completion_error ~stop_reason:expected)
       in
       match err with
       | Error.Provider (Llm_provider.Error.ProviderUnavailable { detail; _ }) ->
         Alcotest.(check bool) "nonempty detail" true (String.trim detail <> "")
       | _ -> Alcotest.fail "expected provider unavailable")
    [ Llm_provider.Types.EndTurn; Llm_provider.Types.MaxTokens ]
;;

(* ── Runner ───────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "stream_accumulator"
    [ "create", [ Alcotest.test_case "initial state" `Quick test_create_initial_state ]
    ; ( "repeating"
      , [ Alcotest.test_case
            "three identical paragraphs end the stream"
            `Quick
            test_repeating_paragraph_ends_the_stream
        ; Alcotest.test_case
            "two do not"
            `Quick
            test_two_occurrences_do_not_end_the_stream
        ; Alcotest.test_case
            "short repeated lines are left alone"
            `Quick
            test_short_repeated_lines_are_left_alone
        ; Alcotest.test_case
            "thinking repeats are not guarded"
            `Quick
            test_thinking_repeats_are_not_guarded
        ] )
    ; ( "accumulate"
      , [ Alcotest.test_case "message_start" `Quick test_accumulate_message_start
        ; Alcotest.test_case
            "message_start no usage"
            `Quick
            test_accumulate_message_start_no_usage
        ; Alcotest.test_case
            "message_start cache"
            `Quick
            test_accumulate_message_start_with_cache
        ; Alcotest.test_case
            "block_start text"
            `Quick
            test_accumulate_content_block_start_text
        ; Alcotest.test_case
            "block_start tool"
            `Quick
            test_accumulate_content_block_start_tool
        ; Alcotest.test_case "text deltas concat" `Quick test_accumulate_text_deltas
        ; Alcotest.test_case
            "delta without start"
            `Quick
            test_accumulate_delta_without_start
        ; Alcotest.test_case
            "repeated text deltas append"
            `Quick
            test_repeated_text_deltas_append
        ; Alcotest.test_case
            "text snapshot resolution is canonical"
            `Quick
            test_text_snapshot_resolution_is_canonical
        ; Alcotest.test_case
            "text snapshot conflict fails closed"
            `Quick
            test_text_snapshot_conflict_fails_closed
        ; Alcotest.test_case
            "incremental text deltas remain incremental"
            `Quick
            test_incremental_text_deltas_remain_incremental
        ; Alcotest.test_case "thinking delta" `Quick test_accumulate_thinking_delta
        ; Alcotest.test_case
            "thinking signature delta"
            `Quick
            test_accumulate_thinking_signature_delta
        ; Alcotest.test_case "input_json delta" `Quick test_accumulate_input_json_delta
        ; Alcotest.test_case "message_delta" `Quick test_accumulate_message_delta
        ; Alcotest.test_case
            "message_delta no stop"
            `Quick
            test_accumulate_message_delta_no_stop
        ; Alcotest.test_case
            "message_delta cache"
            `Quick
            test_accumulate_message_delta_cache_update
        ; Alcotest.test_case "ignores ping/stop/error" `Quick test_accumulate_ignores_ping
        ] )
    ; ( "finalize"
      , [ Alcotest.test_case "text response" `Quick test_finalize_text_response
        ; Alcotest.test_case "thinking block" `Quick test_finalize_thinking_block
        ; Alcotest.test_case
            "thinking signature block"
            `Quick
            test_finalize_thinking_signature_block
        ; Alcotest.test_case
            "redacted thinking block"
            `Quick
            test_finalize_redacted_thinking_block
        ; Alcotest.test_case "tool_use" `Quick test_finalize_tool_use
        ; Alcotest.test_case
            "duplicate tool start before payload is idempotent"
            `Quick
            test_duplicate_tool_start_before_payload_is_idempotent
        ; Alcotest.test_case
            "duplicate tool start after payload fails closed"
            `Quick
            test_duplicate_tool_start_after_payload_fails_closed
        ; Alcotest.test_case
            "conflicting tool start fails closed"
            `Quick
            test_conflicting_tool_start_fails_closed
        ; Alcotest.test_case
            "tool_use rejects non-input deltas"
            `Quick
            test_tool_use_rejects_non_input_delta_kinds
        ; Alcotest.test_case
            "tool_use rejects deltas after stop"
            `Quick
            test_tool_use_rejects_delta_after_stop
        ; Alcotest.test_case
            "conflicting message start fails closed"
            `Quick
            test_conflicting_message_start_fails_closed
        ; Alcotest.test_case
            "message start replay requires exact metadata"
            `Quick
            test_message_start_replay_requires_exact_metadata
        ; Alcotest.test_case
            "terminal state is write-once"
            `Quick
            test_terminal_state_is_write_once
        ; Alcotest.test_case
            "tool start requires complete identity"
            `Quick
            test_tool_start_requires_complete_identity
        ; Alcotest.test_case
            "content kind matches delta kind"
            `Quick
            test_content_kind_and_delta_kind_must_match
        ; Alcotest.test_case
            "unknown content kind is rejected at start"
            `Quick
            test_unknown_content_kind_is_rejected_at_start
        ; Alcotest.test_case
            "media metadata is frozen"
            `Quick
            test_media_metadata_is_frozen_by_first_delta
        ; Alcotest.test_case
            "tool_use invalid json"
            `Quick
            test_finalize_tool_use_invalid_json
        ; Alcotest.test_case
            "tool_use invalid json preserves assembly boundaries"
            `Quick
            test_finalize_tool_use_invalid_json_preserves_assembly_boundaries
        ; Alcotest.test_case
            "tool_use non-object json"
            `Quick
            test_finalize_tool_use_rejects_non_object_json
        ; Alcotest.test_case
            "multi block ordering"
            `Quick
            test_finalize_multi_block_ordering
        ; Alcotest.test_case "no usage" `Quick test_finalize_no_usage
        ; Alcotest.test_case
            "unknown type fails closed"
            `Quick
            test_finalize_unknown_block_type_fails_closed
        ] )
    ; ( "map_http_error"
      , [ Alcotest.test_case "http error" `Quick test_map_http_error_http
        ; Alcotest.test_case "network error" `Quick test_map_http_error_network
        ; Alcotest.test_case
            "provider parse failure"
            `Quick
            test_map_http_error_provider_parse_failure
        ; Alcotest.test_case
            "empty completion maps to unavailable"
            `Quick
            test_map_http_error_empty_completion_maps_to_unavailable
        ] )
    ]
;;
