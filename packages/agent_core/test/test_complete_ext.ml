(** Extended coverage tests for the one-shot Complete public API. *)

open Alcotest
open Llm_provider

let contains_substring ~sub text =
  let sub_len = String.length sub in
  let text_len = String.length text in
  let rec loop index =
    if index + sub_len > text_len
    then false
    else if String.sub text index sub_len = sub
    then true
    else loop (index + 1)
  in
  sub_len = 0 || loop 0
;;

let make_config
      ?(kind = Provider_config.OpenAI_compat)
      ?(model_id = "coverage-model")
      ?(base_url = "http://127.0.0.1:8080")
      ?(headers = [])
      ?(request_path = "/v1/chat/completions")
      ?api_key
      ?min_p
      ?top_p
      ?top_k
      ()
  =
  Provider_config.make
    ~kind
    ~model_id
    ~base_url
    ~headers
    ~request_path
    ?api_key
    ?min_p
    ?top_p
    ?top_k
    ()
;;

let make_usage ?(input_tokens = 11) ?(output_tokens = 7) () : Types.api_usage =
  { input_tokens
  ; output_tokens
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = None
  }
;;

let make_response
      ?(model = "")
      ?(stop_reason = Types.EndTurn)
      ?(content = [ Types.Text "ok" ])
      ?usage
      ()
  =
  { Types.id = "resp-complete-ext"; model; stop_reason; content; usage; telemetry = None }
;;

type metric_probe =
  { mutable cache_hits : int
  ; mutable cache_misses : int
  ; mutable starts : int
  ; mutable ends : int
  ; mutable errors : string list
  ; mutable statuses : int list
  ; mutable token_usage : (int * int) list
  ; mutable tool_calls : int list
  ; mutable streaming_first_chunks : float list
  }

let metric_probe () =
  { cache_hits = 0
  ; cache_misses = 0
  ; starts = 0
  ; ends = 0
  ; errors = []
  ; statuses = []
  ; token_usage = []
  ; tool_calls = []
  ; streaming_first_chunks = []
  }
;;

let metrics_of_probe probe =
  { Metrics.noop with
    on_cache_hit = (fun ~model_id:_ -> probe.cache_hits <- probe.cache_hits + 1)
  ; on_cache_miss = (fun ~model_id:_ -> probe.cache_misses <- probe.cache_misses + 1)
  ; on_request_start = (fun ~model_id:_ -> probe.starts <- probe.starts + 1)
  ; on_request_end = (fun ~model_id:_ ~latency_ms:_ -> probe.ends <- probe.ends + 1)
  ; on_error = (fun ~model_id:_ ~error -> probe.errors <- error :: probe.errors)
  ; on_http_status =
      (fun ~provider:_ ~model_id:_ ~status -> probe.statuses <- status :: probe.statuses)
  ; on_token_usage =
      (fun ~provider:_ ~model_id:_ ~input_tokens ~output_tokens ->
        probe.token_usage <- (input_tokens, output_tokens) :: probe.token_usage)
  ; on_tool_calls =
      (fun ~provider:_ ~model_id:_ ~count ->
        probe.tool_calls <- count :: probe.tool_calls)
  ; on_streaming_first_chunk =
      (fun ~provider:_ ~model_id:_ ~ttfrc_ms ->
        probe.streaming_first_chunks <- ttfrc_ms :: probe.streaming_first_chunks)
  }
;;

let in_memory_cache () =
  let table = Hashtbl.create 4 in
  ({ Cache.get = (fun ~key -> Hashtbl.find_opt table key)
   ; set = (fun ~key ~ttl_sec:_ json -> Hashtbl.replace table key json)
   }
   : Cache.t)
;;

let transport_of_sync sync_response =
  { Llm_transport.complete_sync = (fun _request -> sync_response ())
  ; complete_stream =
      (fun ?on_telemetry:_ ~on_event:_ _request ->
        match sync_response () with
        | { response = Ok resp; _ } -> Ok resp
        | { response = Error err; _ } -> Error err)
  }
;;

let string_of_http_error = function
  | Http_client.HttpError { code; body; _ } -> Printf.sprintf "HTTP %d: %s" code body
  | NetworkError { message; _ } -> message
  | TimeoutError { message; _ } -> message
  | AcceptRejected { reason } -> reason
  | ProviderTerminal { message; _ } -> message
  | ProviderFailure { kind; message } ->
    Http_client.provider_failure_to_string ~kind ~message
;;

let check_typed_empty_completion expected = function
  | Error
      (Http_client.ProviderFailure
         { kind = Http_client.Empty_completion { stop_reason }; _ }) ->
    check bool "typed stop reason" true (stop_reason = expected)
  | Ok _ -> fail "expected empty completion error, got Ok"
  | Error err ->
    failf "expected typed empty completion, got %s" (string_of_http_error err)
;;

(* ── Provider defaults / public helpers ───────────────── *)

let test_gemini_url_variants () =
  let keyed =
    make_config
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~api_key:"secret"
      ()
  in
  check
    string
    "sync keyed"
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:generateContent"
    (Complete_sampling.gemini_url ~config:keyed ~stream:false);
  check
    string
    "stream keyed"
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:streamGenerateContent?alt=sse"
    (Complete_sampling.gemini_url ~config:keyed ~stream:true);
  let no_key =
    make_config
      ~kind:Provider_config.Gemini
      ~model_id:"gemini-3-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ()
  in
  check
    string
    "stream no key"
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:streamGenerateContent?alt=sse"
    (Complete_sampling.gemini_url ~config:no_key ~stream:true)
;;

(* ── complete wrapper paths ───────────────────────────── *)

let test_complete_transport_success_cache_metrics_and_trace_headers () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let probe = metric_probe () in
  let metrics = metrics_of_probe probe in
  let cache = in_memory_cache () in
  let calls = ref 0 in
  let config =
    make_config
      ~headers:[ "traceparent", "old"; "x-base", "base" ]
      ~model_id:"openai-test"
      ()
  in
  let content =
    [ Types.Text "done"
    ; Types.ToolUse { id = "tool-1"; name = "lookup"; input = `Assoc [] }
    ]
  in
  let response = make_response ~content ~usage:(make_usage ()) () in
  let transport =
    { Llm_transport.complete_sync =
        (fun request ->
          incr calls;
          check
            bool
            "traceparent replaced"
            true
            (List.mem ("traceparent", "new") request.config.headers);
          check
            bool
            "tracestate appended"
            true
            (List.mem ("tracestate", "state") request.config.headers);
          check
            bool
            "base header preserved"
            true
            (List.mem ("x-base", "base") request.config.headers);
          { Llm_transport.response = Ok response; latency_ms = Some 42 })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _request -> Ok response)
    }
  in
  let messages = [ Types.user_msg "hello" ] in
  let first =
    Complete.complete
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~transport
      ~config
      ~messages
      ~trace_context:[ "traceparent", "new"; "tracestate", "state" ]
      ~cache
      ~metrics
      ()
  in
  (match first with
   | Ok resp ->
     check string "model patched" "openai-test" resp.model;
     (match resp.telemetry with
      | Some t ->
        check (option int) "latency patched" (Some 42) t.request_latency_ms;
        check (option string) "canonical model" (Some "openai-test") t.canonical_model_id
      | None -> fail "expected telemetry")
   | Error err -> failf "unexpected complete error: %s" (string_of_http_error err));
  let second =
    Complete.complete
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~transport
      ~config
      ~messages
      ~trace_context:[ "traceparent", "new"; "tracestate", "state" ]
      ~cache
      ~metrics
      ()
  in
  (match second with
   | Ok resp -> check string "cached text" "done" (Types.text_of_response resp)
   | Error err -> failf "unexpected cached error: %s" (string_of_http_error err));
  check int "transport called once" 1 !calls;
  check int "cache miss once" 1 probe.cache_misses;
  check int "cache hit once" 1 probe.cache_hits;
  check int "request start once" 1 probe.starts;
  check int "request end once" 1 probe.ends;
  check (list int) "status 200" [ 200 ] (List.rev probe.statuses);
  check (list (pair int int)) "usage" [ 11, 7 ] (List.rev probe.token_usage);
  check (list int) "tool calls" [ 1 ] (List.rev probe.tool_calls)
;;

let test_complete_injected_transport_rejects_typed_empty () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config = make_config ~model_id:"injected-sync-empty" () in
  List.iter
    (fun stop_reason ->
       let response = make_response ~stop_reason ~content:[] () in
       let transport =
         transport_of_sync (fun () ->
           { Llm_transport.response = Ok response; latency_ms = Some 1 })
       in
       Complete.complete
         ~sw
         ~net:(Eio.Stdenv.net env)
         ~transport
         ~config
         ~messages:[ Types.user_msg "hello" ]
         ()
       |> check_typed_empty_completion stop_reason)
    [ Types.EndTurn; Types.MaxTokens ]
;;

let test_complete_stream_injected_transport_rejects_typed_empty () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config = make_config ~model_id:"injected-stream-empty" () in
  List.iter
    (fun stop_reason ->
       let response = make_response ~stop_reason ~content:[] () in
       let transport =
         transport_of_sync (fun () ->
           { Llm_transport.response = Ok response; latency_ms = Some 1 })
       in
       Complete.complete_stream
         ~sw
         ~net:(Eio.Stdenv.net env)
         ~transport
         ~config
         ~messages:[ Types.user_msg "hello" ]
         ~on_event:(fun _ -> ())
         ()
       |> check_typed_empty_completion stop_reason)
    [ Types.EndTurn; Types.MaxTokens ]
;;

let test_complete_cached_empty_fails_before_transport () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let response = make_response ~stop_reason:Types.MaxTokens ~content:[] () in
  let cached_json = Cache.response_to_json response in
  let cache : Cache.t =
    { get = (fun ~key:_ -> Some cached_json); set = (fun ~key:_ ~ttl_sec:_ _ -> ()) }
  in
  let transport_calls = ref 0 in
  let transport =
    transport_of_sync (fun () ->
      incr transport_calls;
      { Llm_transport.response = Ok (make_response ()); latency_ms = Some 1 })
  in
  let result =
    Complete.complete
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~transport
      ~config:(make_config ~model_id:"cached-empty" ())
      ~messages:[ Types.user_msg "hello" ]
      ~cache
      ()
  in
  check int "transport not called" 0 !transport_calls;
  check_typed_empty_completion Types.MaxTokens result
;;

let test_complete_transport_failure_is_one_shot () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let probe = metric_probe () in
  let metrics = metrics_of_probe probe in
  let attempts = ref 0 in
  let config = make_config ~model_id:"openai-one-shot" () in
  let transport =
    transport_of_sync (fun () ->
      incr attempts;
      { Llm_transport.response =
          Error
            (Http_client.HttpError
               { code = 500; body = "temporary"; retry_after_header = None })
      ; latency_ms = Some 3
      })
  in
  (match
     Complete.complete
       ~sw
       ~net:(Eio.Stdenv.net env)
       ~transport
       ~config
       ~messages:[ Types.user_msg "hello" ]
       ~metrics
       ()
   with
   | Error (Http_client.HttpError { code = 500; body = "temporary"; _ }) -> ()
   | Error err -> failf "unexpected typed error: %s" (string_of_http_error err)
   | Ok _ -> fail "expected provider failure");
  check int "one provider attempt" 1 !attempts;
  check (list int) "status" [ 500 ] (List.rev probe.statuses);
  check (list string) "error" [ "HTTP 500" ] (List.rev probe.errors)
;;

let test_complete_stream_transport_success_metrics_and_telemetry () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let probe = metric_probe () in
  let metrics = metrics_of_probe probe in
  let seen_events = ref [] in
  let seen_telemetry = ref [] in
  let seen_wire = ref [] in
  let wire_token = "Authorization: Bearer opaque-token" in
  let config =
    make_config ~model_id:"openai-stream" ~headers:[ "traceparent", "old-stream" ] ()
  in
  let response =
    make_response
      ~content:
        [ Types.Text "streamed"
        ; Types.ToolUse { id = "tool-stream"; name = "search"; input = `Assoc [] }
        ]
      ()
  in
  let transport =
    { Llm_transport.complete_sync =
        (fun _request -> { Llm_transport.response = Ok response; latency_ms = Some 1 })
    ; complete_stream =
        (fun ?on_telemetry ~on_event request ->
          check
            bool
            "stream trace replaced"
            true
            (List.mem ("traceparent", "new-stream") request.config.headers);
          (match request.observe_wire_chunk with
           | None -> fail "injected transport lost the wire observer"
           | Some observe ->
             observe ~provider:"custom" ~model:request.config.model_id ~chunk:wire_token);
          let event = Types.Ping in
          on_event event;
          seen_events := event :: !seen_events;
          (match on_telemetry with
           | Some emit ->
             emit
               (Telemetry_event.Streaming_first_chunk
                  { provider = "openai"
                  ; model = request.config.model_id
                  ; ttfrc_ms = Some 1.5
                  ; requested_at = 0.0
                  })
           | None -> ());
          Ok response)
    }
  in
  (match
     Complete.complete_stream
       ~sw
       ~net:(Eio.Stdenv.net env)
       ~transport
       ~capture_id:"custom-wire"
       ~wire_observer:(fun observation ->
         seen_wire := observation :: !seen_wire;
         Ok ())
       ~config
       ~messages:[ Types.user_msg "hello stream" ]
       ~trace_context:[ "traceparent", "new-stream" ]
       ~on_event:(fun _event -> ())
       ~on_telemetry:(fun event -> seen_telemetry := event :: !seen_telemetry)
       ~metrics
       ()
   with
   | Ok resp ->
     check string "stream model patched" "openai-stream" resp.model;
     (match resp.telemetry with
      | Some t ->
        check bool "stream latency patched" true (Option.is_some t.request_latency_ms);
        check
          (option string)
          "stream canonical model"
          (Some "openai-stream")
          t.canonical_model_id
      | None -> fail "expected stream telemetry")
   | Error err -> failf "unexpected stream error: %s" (string_of_http_error err));
  check int "event observed" 1 (List.length !seen_events);
  check int "telemetry observed" 1 (List.length !seen_telemetry);
  (match !seen_wire with
   | [ (observation : Wire_observer.observation) ] ->
     check
       (option string)
       "wire observation id"
       (Some "custom-wire")
       observation.capture_id;
     check string "wire provider" "custom" observation.provider;
     check string "wire model" "openai-stream" observation.model;
     check
       string
       "wire redacted"
       "Authorization: Bearer [REDACTED]"
       observation.redacted_chunk
   | _ -> fail "expected one redacted wire observation");
  check (list int) "stream tool calls" [ 1 ] (List.rev probe.tool_calls);
  check
    (list (float 0.001))
    "first chunk metric"
    [ 1.5 ]
    (List.rev probe.streaming_first_chunks)
;;

let test_custom_stream_wire_rejection_is_typed_nonfatal () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let response = make_response ~content:[ Types.Text "preserved" ] () in
  let token = "Authorization: Bearer opaque-token" in
  let observations = ref [] in
  let telemetry = ref [] in
  let transport =
    { Llm_transport.complete_sync =
        (fun _ -> { Llm_transport.response = Ok response; latency_ms = None })
    ; complete_stream =
        (fun ?on_telemetry:_ ~on_event:_ request ->
          (match request.observe_wire_chunk with
           | None -> fail "custom transport did not receive OAS wire sink"
           | Some observe ->
             observe ~provider:"custom" ~model:request.config.model_id ~chunk:token);
          Ok response)
    }
  in
  let result =
    Complete.complete_stream
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~transport
      ~capture_id:"custom-rejected"
      ~wire_observer:(fun observation ->
        observations := observation :: !observations;
        Error Wire_observer.{ reason = "caller queue unavailable" })
      ~config:(make_config ~model_id:"custom-model" ())
      ~messages:[ Types.user_msg "hello" ]
      ~on_event:(fun _ -> ())
      ~on_telemetry:(fun event -> telemetry := event :: !telemetry)
      ()
  in
  (match result with
   | Ok response ->
     check string "provider response" "preserved" (Types.text_of_response response)
   | Error err ->
     failf "wire rejection changed provider result: %s" (string_of_http_error err));
  (match !observations with
   | [ observation ] ->
     check
       string
       "redacted custom chunk"
       "Authorization: Bearer [REDACTED]"
       observation.redacted_chunk
   | _ -> fail "expected one custom transport observation");
  match !telemetry with
  | [ Telemetry_event.Wire_observer_failure
        { capture_id = Some "custom-rejected"
        ; provider = "custom"
        ; model = "custom-model"
        ; cause = Observer_rejected { reason = "caller queue unavailable" }
        }
    ] -> ()
  | _ -> fail "expected one exact typed custom-transport rejection"
;;

let test_custom_stream_wire_observer_and_telemetry_exceptions_are_nonfatal () =
  let diagnostics = ref [] in
  Diag.with_sink
    (fun _level ~ctx message -> diagnostics := (ctx, message) :: !diagnostics)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Eio.Switch.run
       @@ fun sw ->
       let response = make_response ~content:[ Types.Text "preserved" ] () in
       let transport =
         { Llm_transport.complete_sync =
             (fun _ -> { Llm_transport.response = Ok response; latency_ms = None })
         ; complete_stream =
             (fun ?on_telemetry:_ ~on_event:_ request ->
               (match request.observe_wire_chunk with
                | None -> fail "custom transport did not receive OAS wire sink"
                | Some observe ->
                  observe
                    ~provider:"custom"
                    ~model:request.config.model_id
                    ~chunk:"raw chunk");
               Ok response)
         }
       in
       let result =
         Complete.complete_stream
           ~sw
           ~net:(Eio.Stdenv.net env)
           ~transport
           ~wire_observer:(fun _ -> failwith "observer unavailable")
           ~config:(make_config ~model_id:"custom-model" ())
           ~messages:[ Types.user_msg "hello" ]
           ~on_event:(fun _ -> ())
           ~on_telemetry:(function
             | Telemetry_event.Wire_observer_failure _ -> failwith "telemetry unavailable"
             | _ -> ())
           ()
       in
       (match result with
        | Ok response ->
          check string "provider response" "preserved" (Types.text_of_response response)
        | Error err ->
          failf
            "observer diagnostics changed provider result: %s"
            (string_of_http_error err));
       check
         bool
         "both callback failures reach diagnostics"
         true
         (List.exists
            (fun (ctx, message) ->
               String.equal ctx "wire_observer"
               && contains_substring ~sub:"telemetry unavailable" message
               && contains_substring ~sub:"observer unavailable" message)
            !diagnostics))
;;

let () =
  run
    "complete_ext"
    [ "helpers", [ test_case "gemini URL variants" `Quick test_gemini_url_variants ]
    ; ( "complete"
      , [ test_case
            "transport success cache metrics and trace headers"
            `Quick
            test_complete_transport_success_cache_metrics_and_trace_headers
        ; test_case
            "provider failure is one shot"
            `Quick
            test_complete_transport_failure_is_one_shot
        ; test_case
            "injected sync rejects typed empty"
            `Quick
            test_complete_injected_transport_rejects_typed_empty
        ; test_case
            "injected stream rejects typed empty"
            `Quick
            test_complete_stream_injected_transport_rejects_typed_empty
        ; test_case
            "cached empty fails before transport"
            `Quick
            test_complete_cached_empty_fails_before_transport
        ; test_case
            "stream transport success metrics and telemetry"
            `Quick
            test_complete_stream_transport_success_metrics_and_telemetry
        ; test_case
            "custom stream wire rejection is typed and nonfatal"
            `Quick
            test_custom_stream_wire_rejection_is_typed_nonfatal
        ; test_case
            "custom stream observer diagnostics are nonfatal"
            `Quick
            test_custom_stream_wire_observer_and_telemetry_exceptions_are_nonfatal
        ] )
    ]
;;
