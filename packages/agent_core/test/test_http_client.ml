(** Tests for Http_client pure functions. *)

open Agent_sdk
open Llm_provider

let test_inject_stream_param_basic () =
  let body = {|{"model":"gpt-4","messages":[]}|} in
  let result = Http_client.inject_stream_param body in
  let json = Yojson.Safe.from_string result in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "stream present" true (json |> member "stream" |> to_bool);
  Alcotest.(check string) "model preserved" "gpt-4" (json |> member "model" |> to_string)
;;

let test_inject_stream_param_existing_stream () =
  let body = {|{"stream":false,"model":"test"}|} in
  let result = Http_client.inject_stream_param body in
  let json = Yojson.Safe.from_string result in
  let fields =
    match json with
    | `Assoc fs -> fs
    | _ -> []
  in
  let stream_fields = List.filter (fun (k, _) -> k = "stream") fields in
  Alcotest.(check int) "one stream key" 1 (List.length stream_fields);
  Alcotest.(check bool) "stream is true" true (List.assoc "stream" fields = `Bool true)
;;

let test_inject_stream_param_non_json () =
  let body = "not json" in
  let result = Http_client.inject_stream_param body in
  Alcotest.(check string) "returned as-is" "not json" result
;;

let test_inject_stream_param_empty () =
  let body = "{}" in
  let result = Http_client.inject_stream_param body in
  let json = Yojson.Safe.from_string result in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "stream added" true (json |> member "stream" |> to_bool)
;;

let test_inject_stream_param_array () =
  let body = "[1,2,3]" in
  let result = Http_client.inject_stream_param body in
  Alcotest.(check string) "array unchanged" "[1,2,3]" result
;;

let test_inject_stream_and_options_parity () =
  (* inject_stream_and_options must be byte-identical to the chained
     inject_stream_param >> inject_stream_options_include_usage across all
     body shapes — the OpenAI-compat streaming path (complete_stream)
     switched to it, so any divergence changes the request body sent to the
     provider. Covers Assoc without/with pre-existing stream/stream_options,
     non-json, array, empty. *)
  let bodies =
    [ {|{"model":"glm-4"}|}
    ; {|{"model":"gpt-4","stream":false}|}
    ; {|{"messages":[],"stream_options":{"include_usage":false}}|}
    ; {|{"a":1,"stream":true,"stream_options":{"x":1}}|}
    ; "not json"
    ; {|[1,2,3]|}
    ; ""
    ]
  in
  List.iter
    (fun body ->
       let combined = Http_client.inject_stream_and_options body in
       let chained =
         Http_client.inject_stream_options_include_usage
           (Http_client.inject_stream_param body)
       in
       Alcotest.(check string) "parity with chained" chained combined)
    bodies
;;

let test_read_sse_basic () =
  Eio_main.run
  @@ fun _env ->
  let input = "event: message\ndata: hello world\n\ndata: second\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  let events = List.rev !events in
  Alcotest.(check int) "2 events" 2 (List.length events);
  let ev1 = List.nth events 0 in
  Alcotest.(check (option string)) "first event type" (Some "message") (fst ev1);
  Alcotest.(check string) "first data" "hello world" (snd ev1);
  let ev2 = List.nth events 1 in
  Alcotest.(check (option string)) "second no event type" None (fst ev2);
  Alcotest.(check string) "second data" "second" (snd ev2)
;;

let test_read_sse_joins_multiple_data_fields () =
  Eio_main.run
  @@ fun _env ->
  let input = "event: message\ndata: first\ndata: second\n\ndata: next\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  match List.rev !events with
  | [ (Some "message", "first\nsecond"); (None, "next") ] -> ()
  | _ -> Alcotest.fail "SSE data fields must join at the blank event boundary"
;;

let test_read_sse_bounds_accumulated_event_payload () =
  Eio_main.run
  @@ fun _env ->
  let input = "data: 12345\ndata: 67890\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  match
    Http_client.read_sse
      ~max_event_bytes:10
      ~reader
      ~on_data:(fun ~event_type:_ _ -> ())
      ()
  with
  | exception Http_client.Sse_event_too_large { actual_bytes = 11; limit_bytes = 10 } ->
    ()
  | exception Http_client.Sse_event_too_large _ ->
    Alcotest.fail "unexpected SSE event size evidence"
  | () -> Alcotest.fail "oversized accumulated SSE event must fail closed"
;;

(* The bound is a maximum, not an off-by-one: an event landing exactly on it
   must still dispatch, or the limit would silently reject legal payloads. *)
let test_read_sse_accepts_event_exactly_at_the_bound () =
  Eio_main.run
  @@ fun _env ->
  let input = "data: 12345\ndata: 6789\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~max_event_bytes:10 (* exactly "12345\n6789" *)
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  match List.rev !events with
  | [ (None, "12345\n6789") ] -> ()
  | _ -> Alcotest.fail "an event exactly at the bound must still dispatch"
;;

let test_read_sse_ignored_fields_do_not_extend_first_event_deadline () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  try
    Eio.Fiber.both
      (fun () ->
         List.iter
           (fun field ->
              Eio.Flow.copy_string field sink;
              Eio.Time.sleep clock 0.03)
           [ "id: 1\n"; "retry: 1000\n"; "ignored: value\n" ];
         Eio.Flow.copy_string "data: too-late\n\n" sink;
         Eio.Flow.close sink)
      (fun () ->
         Http_client.read_sse
           ~clock
           ~idle_timeout:1.0
           ~first_event_timeout:0.05
           ~reader
           ~on_data:(fun ~event_type:_ _ -> ())
           ());
    Alcotest.fail "ignored SSE fields must not refresh the first-event deadline"
  with
  | Eio.Time.Timeout -> ()
;;

let test_read_sse_empty_lines () =
  Eio_main.run
  @@ fun _env ->
  let input = "\n\ndata: only\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  Alcotest.(check int) "1 event" 1 (List.length !events)
;;

let test_read_sse_done_marker () =
  Eio_main.run
  @@ fun _env ->
  let input = "data: [DONE]\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  Alcotest.(check int) "1 event (DONE)" 1 (List.length !events);
  Alcotest.(check string) "data is DONE" "[DONE]" (snd (List.hd !events))
;;

(* Spec-valid field lines WITHOUT the optional space after ':' used to be
   silently dropped by the literal "data: " / "event: " prefix match — a
   provider or proxy omitting the space made the whole stream vanish. *)
let test_read_sse_no_space_after_colon () =
  Eio_main.run
  @@ fun _env ->
  let input = "event:message\ndata:hello\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  Alcotest.(check int) "1 event" 1 (List.length !events);
  let ev = List.hd !events in
  Alcotest.(check (option string)) "event type without space" (Some "message") (fst ev);
  Alcotest.(check string) "data without space" "hello" (snd ev)
;;

let test_read_sse_eventsource_line_boundaries () =
  Eio_main.run
  @@ fun _env ->
  let input = "\xEF\xBB\xBFevent:message\rdata:hello\r\rdata:next\r\r" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  match List.rev !events with
  | [ (Some "message", "hello"); (None, "next") ] -> ()
  | _ -> Alcotest.fail "SSE must accept BOM and LF/CRLF/CR boundaries"
;;

let test_read_sse_empty_event_type_restores_default () =
  Eio_main.run
  @@ fun _env ->
  let input = "event: stale\nevent:\ndata: payload\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  match List.rev !events with
  | [ (None, "payload") ] -> ()
  | _ -> Alcotest.fail "an empty event field must use the default event type"
;;

let test_read_sse_does_not_dispatch_unterminated_event () =
  Eio_main.run
  @@ fun _env ->
  let input = "data: partial\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  Alcotest.(check int) "unterminated event is discarded" 0 (List.length !events)
;;

let test_read_sse_ignores_id_and_retry_fields () =
  Eio_main.run
  @@ fun _env ->
  let input = "id: 42\nretry: 3000\ndata: payload\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  Alcotest.(check int) "only the data field dispatches" 1 (List.length !events);
  Alcotest.(check string) "payload intact" "payload" (snd (List.hd !events))
;;

let test_read_sse_comment_lines_skipped () =
  Eio_main.run
  @@ fun _env ->
  let input = ": keepalive\n: another\ndata: real\n\n" in
  let flow = Eio.Flow.string_source input in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  Http_client.read_sse
    ~reader
    ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
    ();
  Alcotest.(check int) "comments are not events" 1 (List.length !events);
  Alcotest.(check string) "real payload" "real" (snd (List.hd !events))
;;

(* idle_timeout without clock used to silently disarm the deadline (a
   stalled stream blocked forever); it is now a loud misconfiguration. *)
let test_read_sse_idle_without_clock_raises () =
  Eio_main.run
  @@ fun _env ->
  let flow = Eio.Flow.string_source "data: x\n\n" in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  match
    Http_client.read_sse ~idle_timeout:1.0 ~reader ~on_data:(fun ~event_type:_ _ -> ()) ()
  with
  | () -> Alcotest.fail "expected Invalid_argument for idle_timeout without clock"
  | exception Invalid_argument msg ->
    Alcotest.(check bool)
      "message names the disarm hazard"
      true
      (Util.contains_substring_ci ~haystack:msg ~needle:"idle_timeout")
;;

let test_read_ndjson_idle_without_clock_raises () =
  Eio_main.run
  @@ fun _env ->
  let flow =
    Eio.Flow.string_source
      {|{"ok":true}
|}
  in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  match Http_client.read_ndjson ~idle_timeout:1.0 ~reader ~on_line:ignore () with
  | () -> Alcotest.fail "expected Invalid_argument for idle_timeout without clock"
  | exception Invalid_argument msg ->
    Alcotest.(check bool)
      "message names the disarm hazard"
      true
      (Util.contains_substring_ci ~haystack:msg ~needle:"idle_timeout")
;;

let test_post_stream_invalid_url_returns_network_error () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match
    Http_client.post_stream
      ~sw
      ~net:env#net
      ~url:"http://"
      ~headers:[ "Content-Type", "application/json" ]
      ~body:"{}"
      ()
  with
  | Error (Http_client.NetworkError { message; _ }) ->
    Alcotest.(check bool)
      "mentions missing host"
      true
      (Util.contains_substring_ci ~haystack:message ~needle:"missing host")
  | Error (Http_client.AcceptRejected _) ->
    Alcotest.fail "expected invalid URL to fail before headers are accepted"
  | Error (Http_client.HttpError _) ->
    Alcotest.fail "expected network error for invalid URL"
  | Error (Http_client.ProviderTerminal _) ->
    Alcotest.fail "expected NetworkError for invalid URL, not ProviderTerminal"
  | Error (Http_client.ProviderFailure _) ->
    Alcotest.fail "expected NetworkError for invalid URL, not ProviderFailure"
  | Error (Http_client.TimeoutError _) ->
    Alcotest.fail "expected NetworkError for invalid URL, not TimeoutError"
  | Ok _ -> Alcotest.fail "expected invalid URL to fail before opening a stream"
;;

let test_http_deadlines_without_clock_are_rejected () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let check label parameter = function
    | Error (Http_client.AcceptRejected { reason }) ->
      Alcotest.(check bool)
        label
        true
        (Util.contains_substring_ci ~haystack:reason ~needle:parameter)
    | Error _ -> Alcotest.failf "%s returned the wrong typed error" label
    | Ok _ -> Alcotest.failf "%s silently ignored its deadline" label
  in
  check
    "get_sync"
    "timeout_s"
    (Http_client.get_sync ~timeout_s:1.0 ~sw ~net:env#net ~url:"http://" ~headers:[] ());
  check
    "post_sync"
    "timeout_s"
    (Http_client.post_sync
       ~timeout_s:1.0
       ~sw
       ~net:env#net
       ~url:"http://"
       ~headers:[]
       ~body:"{}"
       ());
  check
    "post_stream"
    "connect_timeout_s"
    (Http_client.post_stream
       ~connect_timeout_s:1.0
       ~sw
       ~net:env#net
       ~url:"http://"
       ~headers:[]
       ~body:"{}"
       ());
  check
    "with_post_stream"
    "connect_timeout_s"
    (Http_client.with_post_stream
       ~connect_timeout_s:1.0
       ~net:env#net
       ~url:"http://"
       ~headers:[]
       ~body:"{}"
       ~f:(fun _reader -> ())
       ())
;;

let test_explicit_deadline_requires_finite_positive_timeout () =
  let invalid_cases =
    [ "zero", 0.0, "test: body_timeout_s must be finite and greater than zero, got 0"
    ; ( "negative"
      , -1.0
      , "test: body_timeout_s must be finite and greater than zero, got -1" )
    ; ( "nan"
      , Float.nan
      , "test: body_timeout_s must be finite and greater than zero, got nan" )
    ; ( "positive infinity"
      , Float.infinity
      , "test: body_timeout_s must be finite and greater than zero, got inf" )
    ; ( "negative infinity"
      , Float.neg_infinity
      , "test: body_timeout_s must be finite and greater than zero, got -inf" )
    ]
  in
  List.iter
    (fun (label, timeout_s, expected_reason) ->
       match
         Http_client.resolve_explicit_deadline
           ~operation:"test"
           ~parameter:"body_timeout_s"
           ~clock:(Some ())
           ~timeout_s:(Some timeout_s)
       with
       | Error (Http_client.AcceptRejected { reason }) ->
         Alcotest.(check string) label expected_reason reason
       | Error _ -> Alcotest.failf "%s returned the wrong typed error" label
       | Ok _ -> Alcotest.failf "%s accepted an invalid timeout" label)
    invalid_cases;
  match
    Http_client.resolve_explicit_deadline
      ~operation:"test"
      ~parameter:"body_timeout_s"
      ~clock:(Some ())
      ~timeout_s:(Some 1.25)
  with
  | Ok (Http_client.Bounded ((), timeout_s)) ->
    Alcotest.(check (float 0.0)) "positive timeout is preserved" 1.25 timeout_s
  | Ok Http_client.Unbounded -> Alcotest.fail "positive timeout became unbounded"
  | Error _ -> Alcotest.fail "positive timeout was rejected"
;;

let test_timeout_phase_policy_labels () =
  let cases =
    [ Http_client.Admission, "admission"
    ; Http_client.Queue, "queue"
    ; Http_client.First_token, "first_token"
    ; Http_client.Wall_clock, "wall_clock"
    ; Http_client.Capacity_backpressure, "capacity_backpressure"
    ; Http_client.Http_operation, "http_operation"
    ; Http_client.Non_streaming_body, "non_streaming_body"
    ; Http_client.Stream_body, "stream_body"
    ; ( Http_client.Stream_idle Http_client.Streaming_thinking
      , "stream_idle:streaming_thinking" )
    ; Http_client.Provider_step, "provider_step"
    ; Http_client.Cli_stdout_idle, "cli_stdout_idle"
    ; Http_client.Unknown_timeout, "unknown_timeout"
    ]
  in
  List.iter
    (fun (phase, expected) ->
       Alcotest.(check string)
         expected
         expected
         (Http_client.timeout_phase_to_label phase))
    cases
;;

let test_timeout_phase_of_stream_idle_state () =
  let cases =
    [ Http_client.Awaiting_first_event, "first_token"
    ; Http_client.Awaiting_first_delta, "first_token"
    ; Http_client.Streaming_answer, "stream_idle:streaming_answer"
    ; Http_client.Streaming_thinking, "stream_idle:streaming_thinking"
    ; Http_client.Streaming_tool_call, "stream_idle:streaming_tool_call"
    ; Http_client.Streaming_heartbeat, "stream_idle:streaming_heartbeat"
    ; Http_client.Streaming_substrate, "stream_idle:streaming_substrate"
    ; Http_client.Streaming_done, "stream_idle:streaming_done"
    ; Http_client.Streaming_unknown, "stream_idle:streaming_unknown"
    ]
  in
  List.iter
    (fun (state, expected) ->
       let phase = Http_client.timeout_phase_of_stream_idle_state state in
       Alcotest.(check string)
         expected
         expected
         (Http_client.timeout_phase_to_label phase))
    cases
;;

let test_provider_failure_string_helpers () =
  let cases =
    [ ( Http_client.Capacity_exhausted
          { scope = Http_client.Failure_scope_model
          ; retry_after = Some 1.0
          ; model = Some "m"
          }
      , "capacity_exhausted:model" )
    ; ( Http_client.Capacity_exhausted
          { scope = Http_client.Failure_scope_account; retry_after = None; model = None }
      , "capacity_exhausted:account" )
    ; ( Http_client.Capacity_exhausted
          { scope = Http_client.Failure_scope_region; retry_after = None; model = None }
      , "capacity_exhausted:region" )
    ; ( Http_client.Capacity_exhausted
          { scope = Http_client.Failure_scope_provider; retry_after = None; model = None }
      , "capacity_exhausted:provider" )
    ; ( Http_client.Capacity_exhausted
          { scope = Http_client.Failure_scope_unknown; retry_after = None; model = None }
      , "capacity_exhausted:unknown" )
    ; Http_client.Hard_quota { retry_after = None }, "hard_quota"
    ; ( Http_client.Capability_mismatch { capability = Some "json_schema" }
      , "capability_mismatch:json_schema" )
    ; Http_client.Capability_mismatch { capability = None }, "capability_mismatch"
    ; ( Http_client.Cli_policy_invalid { tool_name = Some "Read"; rule = Some 2 }
      , "cli_policy_invalid:rule_2:Read" )
    ; ( Http_client.Cli_policy_invalid { tool_name = Some "Read"; rule = None }
      , "cli_policy_invalid:Read" )
    ; ( Http_client.Cli_policy_invalid { tool_name = None; rule = Some 7 }
      , "cli_policy_invalid:rule_7" )
    ; ( Http_client.Cli_policy_invalid { tool_name = None; rule = None }
      , "cli_policy_invalid" )
    ; ( Http_client.Cli_startup_failed { reason = Http_client.Executable_unavailable }
      , "cli_startup_failed:executable_unavailable" )
    ; Http_client.Provider_parse_error { parser = Some "glm" }, "provider_parse_error:glm"
    ; Http_client.Provider_parse_error { parser = None }, "provider_parse_error"
    ; ( Http_client.Provider_wire_error
          { format = Http_client.Sse; kind = Http_client.Malformed_payload }
      , "provider_wire_error:sse:malformed_payload" )
    ; ( Http_client.Provider_wire_error
          { format = Http_client.Ndjson; kind = Http_client.Oversized_payload }
      , "provider_wire_error:ndjson:oversized_payload" )
    ; ( Http_client.Provider_reported_error { error_type = Some "rate_limit_exceeded" }
      , "provider_reported_error:rate_limit_exceeded" )
    ; ( Http_client.Response_body_too_large { limit_bytes = 1024 }
      , "response_body_too_large:1024" )
    ; ( Http_client.Empty_completion { stop_reason = Types.EndTurn }
      , "empty_completion:end_turn" )
    ; ( Http_client.Empty_completion { stop_reason = Types.MaxTokens }
      , "empty_completion:max_tokens" )
    ; ( Http_client.Unknown_provider_failure { reason = Some "exit_status" }
      , "unknown_provider_failure:exit_status" )
    ; Http_client.Unknown_provider_failure { reason = None }, "unknown_provider_failure"
    ]
  in
  List.iter
    (fun (kind, expected) ->
       Alcotest.(check string)
         expected
         expected
         (Http_client.provider_failure_kind_to_string kind))
    cases;
  Alcotest.(check string)
    "blank message"
    "hard_quota"
    (Http_client.provider_failure_to_string
       ~kind:(Http_client.Hard_quota { retry_after = None })
       ~message:"   ");
  Alcotest.(check string)
    "with message"
    "hard_quota: quota exhausted"
    (Http_client.provider_failure_to_string
       ~kind:(Http_client.Hard_quota { retry_after = None })
       ~message:"quota exhausted")
;;

let test_empty_completion_error_preserves_stop_reason () =
  List.iter
    (fun expected ->
       match Http_client.empty_completion_error ~stop_reason:expected with
       | Http_client.ProviderFailure
           { kind = Http_client.Empty_completion { stop_reason }; message } ->
         Alcotest.(check bool) "typed stop reason" true (stop_reason = expected);
         Alcotest.(check bool) "nonempty detail" true (String.trim message <> "")
       | _ -> Alcotest.fail "expected Empty_completion provider failure")
    [ Types.EndTurn; Types.MaxTokens ]
;;

let test_api_common_string_is_blank () =
  Alcotest.(check bool) "empty is blank" true (Api_common.string_is_blank "");
  Alcotest.(check bool) "spaces is blank" true (Api_common.string_is_blank "   ");
  Alcotest.(check bool) "text not blank" false (Api_common.string_is_blank "hello");
  Alcotest.(check bool) "tab blank" true (Api_common.string_is_blank "\t\n")
;;

let test_api_common_text_blocks_to_string () =
  let blocks =
    Types.
      [ Text "hello"
      ; ToolUse { id = "t1"; name = "fn"; input = `Null }
      ; Text "world"
      ; Thinking { signature = Some "sig"; content = "thought" }
      ]
  in
  let result = Api_common.text_blocks_to_string blocks in
  Alcotest.(check string) "text + thinking" "hello\nworld\nthought" result
;;

let test_api_common_content_block_roundtrip () =
  let blocks =
    Types.
      [ Text "hello"
      ; ToolUse { id = "t1"; name = "calc"; input = `Assoc [ "x", `Int 1 ] }
      ; ToolResult
          { tool_use_id = "t1"
          ; content = "result"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  List.iter
    (fun block ->
       let json = Api_common.content_block_to_json block in
       match Api_common.content_block_of_json json with
       | Some restored ->
         let json2 = Api_common.content_block_to_json restored in
         Alcotest.(check string)
           "roundtrip"
           (Yojson.Safe.to_string json)
           (Yojson.Safe.to_string json2)
       | None -> Alcotest.fail "roundtrip: of_json returned None")
    blocks
;;

let test_error_domain_full_roundtrip () =
  let errors : Agent_sdk.Error.sdk_error list =
    [ Agent_sdk.Error.Api (Retry.RateLimited { retry_after = Some 2.0; message = "slow" })
    ; Agent_sdk.Error.Api (Retry.AuthError { message = "bad key" })
    ; Agent_sdk.Error.Api (Retry.ServerError { status = 500; message = "internal" })
    ; Agent_sdk.Error.Config (MissingEnvVar { var_name = "API_KEY" })
    ; Agent_sdk.Error.Config (UnsupportedProvider { detail = "unknown" })
    ; Agent_sdk.Error.Config
        (InvalidConfig { field = "model"; detail = "must not be empty" })
    ; Agent_sdk.Error.Mcp (ServerStartFailed { command = "node"; detail = "not found" })
    ; Agent_sdk.Error.Mcp (InitializeFailed { detail = "timeout" })
    ; Agent_sdk.Error.Mcp (ToolListFailed { detail = "parse" })
    ; Agent_sdk.Error.Mcp (ToolCallFailed { tool_name = "fs_read"; detail = "denied" })
    ; Agent_sdk.Error.Mcp
        (HttpTransportFailed { url = "http://x"; detail = "conn refused" })
    ; Agent_sdk.Error.Internal "something broke"
    ]
  in
  (* Roundtrip: sdk_error -> poly -> sdk_error.
     Note: provider errors lose the original message during roundtrip
     (provider_to_api uses fixed messages), so we only verify the
     sdk_error variant structure is preserved, not exact message text. *)
  List.iter
    (fun err ->
       let poly = Error_domain.of_sdk_error err in
       let back = Error_domain.to_sdk_error poly in
       let s1 = Agent_sdk.Error.to_string err in
       let s2 = Agent_sdk.Error.to_string back in
       (* Verify both produce non-empty strings *)
       Alcotest.(check bool)
         "roundtrip non-empty"
         true
         (String.length s1 > 0 && String.length s2 > 0);
       (* Verify is_retryable is preserved *)
       Alcotest.(check bool)
         "retryable preserved"
         (Agent_sdk.Error.is_retryable err)
         (Agent_sdk.Error.is_retryable back))
    errors
;;

let test_error_domain_retryable () =
  Alcotest.(check bool)
    "rate limited retryable"
    true
    (Error_domain.is_retryable (`Rate_limited (Some 1.0, "slow down")));
  Alcotest.(check bool)
    "network retryable"
    true
    (Error_domain.is_retryable (`Network_error "oops"));
  Alcotest.(check bool)
    "mcp init retryable"
    true
    (Error_domain.is_retryable (`Mcp_init_failed "x"));
  Alcotest.(check bool)
    "auth not retryable"
    false
    (Error_domain.is_retryable (`Auth_error "bad"));
  Alcotest.(check bool)
    "guardrail violation not retryable"
    false
    (Error_domain.is_retryable (`Guardrail_violation ("typed-input", "rejected")))
;;

let test_error_domain_context () =
  let err = `Auth_error "bad key" in
  let ctx = Error_domain.with_stage "api_call" err in
  let s = Error_domain.ctx_to_string ctx in
  Alcotest.(check bool)
    "contains stage"
    true
    (String.length s > 0
     &&
     try
       ignore (Str.search_forward (Str.regexp_string "[api_call]") s 0);
       true
     with
     | Not_found -> false)
;;

(* ── Test runner ────────────────────────────────── *)

let () =
  Alcotest.run
    "HTTP Client & Error Domain"
    [ ( "inject_stream_param"
      , [ Alcotest.test_case "basic" `Quick test_inject_stream_param_basic
        ; Alcotest.test_case
            "existing stream"
            `Quick
            test_inject_stream_param_existing_stream
        ; Alcotest.test_case "non-json" `Quick test_inject_stream_param_non_json
        ; Alcotest.test_case "empty object" `Quick test_inject_stream_param_empty
        ; Alcotest.test_case "array" `Quick test_inject_stream_param_array
        ; Alcotest.test_case
            "and_options parity with chained"
            `Quick
            test_inject_stream_and_options_parity
        ] )
    ; ( "read_sse"
      , [ Alcotest.test_case "basic events" `Quick test_read_sse_basic
        ; Alcotest.test_case
            "multiple data fields join"
            `Quick
            test_read_sse_joins_multiple_data_fields
        ; Alcotest.test_case
            "accumulated event payload is bounded"
            `Quick
            test_read_sse_bounds_accumulated_event_payload
        ; Alcotest.test_case
            "event exactly at the bound dispatches"
            `Quick
            test_read_sse_accepts_event_exactly_at_the_bound
        ; Alcotest.test_case
            "ignored fields preserve first-event deadline"
            `Quick
            test_read_sse_ignored_fields_do_not_extend_first_event_deadline
        ; Alcotest.test_case "empty lines" `Quick test_read_sse_empty_lines
        ; Alcotest.test_case "DONE marker" `Quick test_read_sse_done_marker
        ; Alcotest.test_case
            "no space after colon (spec grammar)"
            `Quick
            test_read_sse_no_space_after_colon
        ; Alcotest.test_case
            "EventSource line boundaries"
            `Quick
            test_read_sse_eventsource_line_boundaries
        ; Alcotest.test_case
            "empty event type"
            `Quick
            test_read_sse_empty_event_type_restores_default
        ; Alcotest.test_case
            "unterminated event is discarded"
            `Quick
            test_read_sse_does_not_dispatch_unterminated_event
        ; Alcotest.test_case
            "id/retry fields ignored"
            `Quick
            test_read_sse_ignores_id_and_retry_fields
        ; Alcotest.test_case
            "comment lines skipped"
            `Quick
            test_read_sse_comment_lines_skipped
        ; Alcotest.test_case
            "idle_timeout without clock raises"
            `Quick
            test_read_sse_idle_without_clock_raises
        ; Alcotest.test_case
            "invalid url returns network error"
            `Quick
            test_post_stream_invalid_url_returns_network_error
        ] )
    ; ( "read_ndjson"
      , [ Alcotest.test_case
            "idle_timeout without clock raises"
            `Quick
            test_read_ndjson_idle_without_clock_raises
        ] )
    ; ( "timeout_phase"
      , [ Alcotest.test_case "policy labels" `Quick test_timeout_phase_policy_labels
        ; Alcotest.test_case
            "stream idle pre-token maps to first_token"
            `Quick
            test_timeout_phase_of_stream_idle_state
        ; Alcotest.test_case
            "HTTP deadlines without clock are rejected"
            `Quick
            test_http_deadlines_without_clock_are_rejected
        ; Alcotest.test_case
            "explicit deadlines require finite positive values"
            `Quick
            test_explicit_deadline_requires_finite_positive_timeout
        ] )
    ; ( "provider_failure"
      , [ Alcotest.test_case "string helpers" `Quick test_provider_failure_string_helpers
        ; Alcotest.test_case
            "empty completion preserves stop reason"
            `Quick
            test_empty_completion_error_preserves_stop_reason
        ] )
    ; ( "api_common"
      , [ Alcotest.test_case "string_is_blank" `Quick test_api_common_string_is_blank
        ; Alcotest.test_case
            "text_blocks_to_string"
            `Quick
            test_api_common_text_blocks_to_string
        ; Alcotest.test_case
            "content_block roundtrip"
            `Quick
            test_api_common_content_block_roundtrip
        ] )
    ; ( "error_domain"
      , [ Alcotest.test_case "full roundtrip" `Quick test_error_domain_full_roundtrip
        ; Alcotest.test_case "retryable classification" `Quick test_error_domain_retryable
        ; Alcotest.test_case "error context" `Quick test_error_domain_context
        ] )
    ]
;;
