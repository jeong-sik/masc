(** RFC-OAS-019 Phase 1 unit tests.

    Minimal Phase 1 coverage: the new [Streaming_summary] variant
    serialises round-trip, exposes the right [event_type_name], and the
    [streaming_terminal] / [streaming_kind_breakdown] auxiliary types
    round-trip too.

    Full integration coverage (100-chunk synthetic completion, cancel
    mid-stream, provider error) is deferred to a follow-up PR — those
    paths require an SSE mock that does not exist yet in this test
    suite and would scope-creep the Phase 1 change. *)

module T = Llm_provider.Telemetry_event

let sample_breakdown : T.streaming_kind_breakdown =
  { thinking = 5
  ; answer = 300
  ; tool_call_start = 1
  ; tool_call_arg_delta = 4
  ; tool_call_complete = 1
  ; substrate = 0
  ; heartbeat = 8
  ; done_ = 1
  }
;;

let sample_summary : T.t =
  T.Streaming_summary
    { provider = "openai_compat"
    ; model = "glm-5.1"
    ; chunk_count = 314
    ; kind_breakdown = sample_breakdown
    ; ttft_ms = Some 250.0
    ; prefill_ms = None
    ; total_ms = Some 12_000.0
    ; inter_chunk_ms_p50 = Some 40.0
    ; inter_chunk_ms_p95 = Some 80.0
    ; inter_chunk_ms_max = Some 150.0
    ; terminal = T.Terminal_done
    }
;;

let test_event_type_name () =
  Alcotest.(check string)
    "Streaming_summary event_type_name"
    "streaming_summary"
    (T.event_type_name sample_summary)
;;

let test_yojson_roundtrip_summary () =
  let json = T.to_yojson sample_summary in
  match T.of_yojson json with
  | Ok roundtripped ->
    Alcotest.(check bool) "structural equality" true (roundtripped = sample_summary)
  | Error msg -> Alcotest.fail (Printf.sprintf "of_yojson failed: %s" msg)
;;

let test_terminal_error_roundtrip () =
  let summary_with_error : T.t =
    T.Streaming_summary
      { provider = "openai_compat"
      ; model = "glm-5.1"
      ; chunk_count = 12
      ; kind_breakdown =
          { thinking = 0
          ; answer = 10
          ; tool_call_start = 0
          ; tool_call_arg_delta = 0
          ; tool_call_complete = 0
          ; substrate = 0
          ; heartbeat = 2
          ; done_ = 0
          }
      ; ttft_ms = Some 110.0
      ; prefill_ms = Some 35.0
      ; total_ms = Some 2_400.0
      ; inter_chunk_ms_p50 = Some 25.0
      ; inter_chunk_ms_p95 = Some 60.0
      ; inter_chunk_ms_max = Some 120.0
      ; terminal = T.Terminal_error "stream_idle_timeout_s_exceeded:streaming_answer"
      }
  in
  let json = T.to_yojson summary_with_error in
  match T.of_yojson json with
  | Ok roundtripped ->
    Alcotest.(check bool)
      "terminal-error round-trip"
      true
      (roundtripped = summary_with_error)
  | Error msg -> Alcotest.fail (Printf.sprintf "of_yojson failed: %s" msg)
;;

let test_kind_breakdown_roundtrip () =
  let json = T.streaming_kind_breakdown_to_yojson sample_breakdown in
  match T.streaming_kind_breakdown_of_yojson json with
  | Ok roundtripped ->
    Alcotest.(check bool)
      "kind_breakdown structural equality"
      true
      (roundtripped = sample_breakdown)
  | Error msg -> Alcotest.fail (Printf.sprintf "kind_breakdown of_yojson failed: %s" msg)
;;

let test_terminal_cancelled_roundtrip () =
  let json = T.streaming_terminal_to_yojson T.Terminal_cancelled in
  match T.streaming_terminal_of_yojson json with
  | Ok T.Terminal_cancelled -> ()
  | Ok _ -> Alcotest.fail "expected Terminal_cancelled after roundtrip"
  | Error msg -> Alcotest.fail (Printf.sprintf "terminal of_yojson failed: %s" msg)
;;

(* RFC-OAS-020 TTFT helper tests *)

module Streaming = Llm_provider.Streaming
module Types = Llm_provider.Types

let make_openai_chunk
      ?delta_content
      ?delta_reasoning
      ?delta_reasoning_details
      ?(delta_tool_calls = [])
      ()
  : Streaming.openai_chunk
  =
  { chunk_id = "c1"
  ; chunk_model = "m"
  ; delta_content
  ; delta_reasoning
  ; delta_reasoning_details
  ; delta_tool_calls
  ; finish_reason = None
  ; chunk_usage = None
  }
;;

let test_chunk_has_non_empty_delta_content () =
  let c = make_openai_chunk ~delta_content:"hello" () in
  Alcotest.(check bool)
    "non-empty content is a token signal"
    true
    (Streaming.chunk_has_non_empty_delta c)
;;

let test_chunk_empty_delta_is_not_token () =
  let c = make_openai_chunk ~delta_content:"" () in
  Alcotest.(check bool)
    "empty string content is not a token"
    false
    (Streaming.chunk_has_non_empty_delta c)
;;

let test_chunk_only_reasoning_is_token () =
  let c = make_openai_chunk ~delta_reasoning:"thinking..." () in
  Alcotest.(check bool)
    "reasoning-only chunk is a token"
    true
    (Streaming.chunk_has_non_empty_delta c)
;;

let test_chunk_reasoning_details_is_token () =
  let detail : Types.reasoning_detail =
    { raw = `Assoc [ "text", `String "thinking..." ]; text = Some "thinking..." }
  in
  let c =
    make_openai_chunk
      ~delta_reasoning_details:
        { delta_reasoning_content = None; delta_details = [ detail ] }
      ()
  in
  Alcotest.(check bool)
    "reasoning_details chunk is a token"
    true
    (Streaming.chunk_has_non_empty_delta c)
;;

let test_chunk_empty_reasoning_details_is_not_token () =
  let c =
    make_openai_chunk
      ~delta_reasoning_details:{ delta_reasoning_content = None; delta_details = [] }
      ()
  in
  Alcotest.(check bool)
    "empty reasoning_details chunk is not a token"
    false
    (Streaming.chunk_has_non_empty_delta c)
;;

let test_chunk_tool_call_is_token () =
  let tc : Streaming.openai_tool_call_delta =
    { tc_index = 0
    ; tc_id = Some "call_1"
    ; tc_name = Some "fetch"
    ; tc_arguments = Some (Streaming.Args_complete "{}")
    }
  in
  let c = make_openai_chunk ~delta_tool_calls:[ tc ] () in
  Alcotest.(check bool)
    "tool_call delta is a token"
    true
    (Streaming.chunk_has_non_empty_delta c)
;;

let test_chunk_finish_only_is_not_token () =
  let c = make_openai_chunk () in
  Alcotest.(check bool)
    "finish-only / empty chunk is not a token"
    false
    (Streaming.chunk_has_non_empty_delta c)
;;

let test_sse_event_message_start_is_not_token () =
  let e = Types.MessageStart { id = "x"; model = "m"; usage = None } in
  Alcotest.(check bool)
    "MessageStart is prelude, not token"
    false
    (Streaming.sse_event_is_first_token_signal e)
;;

let test_sse_event_text_delta_is_token () =
  let e = Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "hello" } in
  Alcotest.(check bool)
    "TextDelta with content is a token"
    true
    (Streaming.sse_event_is_first_token_signal e)
;;

let test_sse_event_empty_text_delta_is_not_token () =
  let e = Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "" } in
  Alcotest.(check bool)
    "empty TextDelta is not a token"
    false
    (Streaming.sse_event_is_first_token_signal e)
;;

let test_sse_event_reasoning_details_is_token_not_deliverable () =
  let detail : Types.reasoning_detail =
    { raw = `Assoc [ "text", `String "thinking..." ]; text = Some "thinking..." }
  in
  let e =
    Types.ContentBlockDelta
      { index = 0
      ; delta =
          Types.ReasoningDetailsDelta { reasoning_content = None; details = [ detail ] }
      }
  in
  Alcotest.(check bool)
    "ReasoningDetailsDelta is a token"
    true
    (Streaming.sse_event_is_first_token_signal e);
  Alcotest.(check bool)
    "ReasoningDetailsDelta is not deliverable progress"
    false
    (Streaming.sse_event_is_deliverable_progress_signal e)
;;

let test_sse_event_ping_is_not_token () =
  Alcotest.(check bool)
    "Ping is not a token"
    false
    (Streaming.sse_event_is_first_token_signal Types.Ping)
;;

let () =
  Alcotest.run
    "RFC-OAS-019 Streaming_summary"
    [ ( "event_type_name"
      , [ Alcotest.test_case
            "Streaming_summary maps to streaming_summary"
            `Quick
            test_event_type_name
        ] )
    ; ( "yojson"
      , [ Alcotest.test_case
            "Streaming_summary round-trip (Terminal_done)"
            `Quick
            test_yojson_roundtrip_summary
        ; Alcotest.test_case
            "Streaming_summary round-trip (Terminal_error)"
            `Quick
            test_terminal_error_roundtrip
        ; Alcotest.test_case
            "streaming_kind_breakdown round-trip"
            `Quick
            test_kind_breakdown_roundtrip
        ; Alcotest.test_case
            "streaming_terminal Cancelled round-trip"
            `Quick
            test_terminal_cancelled_roundtrip
        ] )
    ; ( "RFC-OAS-020 token classification"
      , [ Alcotest.test_case
            "chunk_has_non_empty_delta: content"
            `Quick
            test_chunk_has_non_empty_delta_content
        ; Alcotest.test_case
            "chunk_has_non_empty_delta: empty content rejected"
            `Quick
            test_chunk_empty_delta_is_not_token
        ; Alcotest.test_case
            "chunk_has_non_empty_delta: reasoning only"
            `Quick
            test_chunk_only_reasoning_is_token
        ; Alcotest.test_case
            "chunk_has_non_empty_delta: reasoning details"
            `Quick
            test_chunk_reasoning_details_is_token
        ; Alcotest.test_case
            "chunk_has_non_empty_delta: empty reasoning details rejected"
            `Quick
            test_chunk_empty_reasoning_details_is_not_token
        ; Alcotest.test_case
            "chunk_has_non_empty_delta: tool call"
            `Quick
            test_chunk_tool_call_is_token
        ; Alcotest.test_case
            "chunk_has_non_empty_delta: finish-only rejected"
            `Quick
            test_chunk_finish_only_is_not_token
        ; Alcotest.test_case
            "sse_event_is_first_token_signal: MessageStart rejected"
            `Quick
            test_sse_event_message_start_is_not_token
        ; Alcotest.test_case
            "sse_event_is_first_token_signal: TextDelta accepted"
            `Quick
            test_sse_event_text_delta_is_token
        ; Alcotest.test_case
            "sse_event_is_first_token_signal: empty TextDelta rejected"
            `Quick
            test_sse_event_empty_text_delta_is_not_token
        ; Alcotest.test_case
            "sse_event_is_first_token_signal: ReasoningDetailsDelta hidden"
            `Quick
            test_sse_event_reasoning_details_is_token_not_deliverable
        ; Alcotest.test_case
            "sse_event_is_first_token_signal: Ping rejected"
            `Quick
            test_sse_event_ping_is_not_token
        ] )
    ]
;;
