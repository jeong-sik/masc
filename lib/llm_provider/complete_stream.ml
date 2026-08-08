(** Streaming HTTP completion implementation.

    Extracted from {!Complete} to keep the entry-point module
    focused on orchestration and retry logic.

    @since 0.205.9 *)

include Complete_common
include Complete_sampling

let emit_stream_event on_event evt =
  try on_event evt with
  | exn ->
    Reserved_exn.reraise_if_reserved exn;
    Diag.warn
      "complete_stream"
      "stream event callback raised: %s"
      (Printexc.to_string exn)
;;

let record_streaming_metrics (metrics : Metrics.t) = function
  | Telemetry_event.Streaming_first_chunk { provider; model; ttfrc_ms = Some ttfrc_ms; _ }
    -> metrics.on_streaming_first_chunk ~provider ~model_id:model ~ttfrc_ms
  | Telemetry_event.Streaming_first_chunk { ttfrc_ms = None; _ } -> ()
  | Streaming_summary _
  | Thinking_complete _
  | Timeout _
  | Prefill_complete _
  | Wire_observer_failure _ -> ()
;;

let%test "OpenAI-compatible parser preserves a typed provider error" =
  match
    Streaming.parse_openai_sse_chunk
      {|{"error":{"type":"rate_limit_exceeded","message":"slow down"}}|}
  with
  | Streaming.Openai_provider_error { message; error_type; _ } ->
    String.equal message "slow down"
    &&
      (match error_type with
      | Some "rate_limit_exceeded" -> true
      | Some _ | None -> false)
  | Streaming.Openai_chunk _
  | Streaming.Openai_done
  | Streaming.Openai_empty
  | Streaming.Openai_parse_failed _ -> false
;;

let%test "OpenAI-compatible parser classifies the DONE sentinel" =
  match Streaming.parse_openai_sse_chunk "[DONE]" with
  | Streaming.Openai_done -> true
  | Streaming.Openai_chunk _
  | Streaming.Openai_empty
  | Streaming.Openai_provider_error _
  | Streaming.Openai_parse_failed _ -> false
;;

let%test "OpenAI-compatible parser classifies a normal content chunk" =
  match
    Streaming.parse_openai_sse_chunk {|{"id":"c","choices":[{"delta":{"content":"hi"}}]}|}
  with
  | Streaming.Openai_chunk _ -> true
  | Streaming.Openai_done
  | Streaming.Openai_empty
  | Streaming.Openai_provider_error _
  | Streaming.Openai_parse_failed _ -> false
;;

(* Per-provider clean-stream regression guards for the phantom-completion check
   (finalize returns Error when no terminal [stop_reason] was seen -- see
   [Complete_stream_acc.finalize_stream_acc]). Each backend's REAL wire terminal,
   run through its actual parser + converter, must set the terminal flag so a
   clean stream finalizes [Ok] -- never a false truncation. The OpenAI-compat
   OpenAI-compatible parser outcome is converted through one event projection,
   including its terminal sentinel and typed failures. *)
let accumulate_events acc events =
  List.iter (Complete_stream_acc.accumulate_event acc) events
;;

let accumulate_openai_payload acc state payload =
  let events, _telemetry =
    Streaming.parse_openai_sse_chunk payload
    |> Streaming.openai_sse_parse_result_to_events state
  in
  accumulate_events acc events
;;

let%test
    "clean stream finalizes Ok: OpenAI-compat finish_reason (covers GLM/Kimi/DashScope)"
  =
  let acc = Complete_stream_acc.create_stream_acc () in
  let st = Streaming.create_openai_stream_state ~provider:"openai" ~model:"m" () in
  accumulate_openai_payload acc st {|{"choices":[{"delta":{},"finish_reason":"stop"}]}|};
  match Complete_stream_acc.finalize_stream_acc acc with
  | Ok _ -> true
  | Error _ -> false
;;

let%test "clean stream finalizes Ok: Anthropic message_delta stop_reason" =
  let acc = Complete_stream_acc.create_stream_acc () in
  (match
     Streaming.parse_sse_event
       (Some "message_delta")
       {|{"delta":{"stop_reason":"end_turn"}}|}
   with
   | Some evt -> Complete_stream_acc.accumulate_event acc evt
   | None -> ());
  match Complete_stream_acc.finalize_stream_acc acc with
  | Ok _ -> true
  | Error _ -> false
;;

let%test "clean stream finalizes Ok: Gemini finishReason" =
  let acc = Complete_stream_acc.create_stream_acc () in
  let st = Streaming.create_openai_stream_state ~provider:"gemini" ~model:"m" () in
  (match
     Streaming.parse_gemini_sse_chunk
       {|{"candidates":[{"content":{"parts":[{"text":"hi"}]},"finishReason":"STOP"}]}|}
   with
   | Streaming.Gemini_chunk chunk ->
     (match Streaming.gemini_chunk_to_events st chunk with
      | Ok (events, _telemetry) -> accumulate_events acc events
      | Error _ -> ())
   | Streaming.Gemini_unsupported_part _ -> ()
   | Streaming.Gemini_unsupported_response _ -> ()
   | Streaming.Gemini_parse_failed _ -> ());
  match Complete_stream_acc.finalize_stream_acc acc with
  | Ok _ -> true
  | Error _ -> false
;;

let%test "clean stream finalizes Ok: Ollama done:true" =
  let acc = Complete_stream_acc.create_stream_acc () in
  let st = Streaming.create_openai_stream_state ~provider:"ollama" ~model:"m" () in
  (match
     Streaming.parse_ollama_ndjson_chunk
       {|{"model":"m","done":true,"done_reason":"stop","message":{"role":"assistant","content":""}}|}
   with
   | Streaming.Ollama_chunk chunk ->
     accumulate_events acc (fst (Streaming.ollama_chunk_to_events st chunk))
   | Streaming.Ollama_provider_error _ | Streaming.Ollama_parse_failed _ -> ());
  match Complete_stream_acc.finalize_stream_acc acc with
  | Ok _ -> true
  | Error _ -> false
;;

let%test "Ollama done without reason finalizes typed incomplete" =
  let acc = Complete_stream_acc.create_stream_acc () in
  let st = Streaming.create_openai_stream_state ~provider:"ollama" ~model:"m" () in
  (match
     Streaming.parse_ollama_ndjson_chunk
       {|{"model":"m","done":true,"message":{"role":"assistant","content":"partial"}}|}
   with
   | Streaming.Ollama_chunk chunk ->
     accumulate_events acc (fst (Streaming.ollama_chunk_to_events st chunk))
   | Streaming.Ollama_provider_error _ | Streaming.Ollama_parse_failed _ -> ());
  match Complete_stream_acc.finalize_stream_acc acc with
  | Error (Types.Stream_incomplete { reason = "stream_terminated_without_stop_reason" })
    -> true
  | Error _ | Ok _ -> false
;;

let%test "Responses terminal event without status finalizes typed incomplete" =
  let acc = Complete_stream_acc.create_stream_acc () in
  let st = Streaming.create_openai_stream_state ~provider:"openai" ~model:"m" () in
  let events, _ =
    Streaming.responses_sse_to_events
      st
      (Some "response.completed")
      {|{"response":{"id":"resp-1","model":"m","output":[]}}|}
  in
  accumulate_events acc events;
  match Complete_stream_acc.finalize_stream_acc acc with
  | Error (Types.Stream_incomplete { reason = "stream_terminal_without_stop_reason" }) ->
    true
  | Error _ | Ok _ -> false
;;

let%test "truncated stream (no terminal stop_reason) finalizes Error, not phantom Ok" =
  let acc = Complete_stream_acc.create_stream_acc () in
  Complete_stream_acc.accumulate_event
    acc
    (Types.ContentBlockStart
       { index = 0; content_type = "text"; tool_id = None; tool_name = None });
  Complete_stream_acc.accumulate_event
    acc
    (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "partial" });
  match Complete_stream_acc.finalize_stream_acc acc with
  | Error _ -> true
  | Ok _ -> false
;;

(* A [data: [DONE]] sentinel proves transport closure, but cannot invent the
   missing model stop reason. The completion stays fail-closed. *)
let%test "OpenAI-compat [DONE] without finish_reason fails closed" =
  let acc = Complete_stream_acc.create_stream_acc () in
  let st = Streaming.create_openai_stream_state ~provider:"openai" ~model:"m" () in
  accumulate_openai_payload
    acc
    st
    {|{"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}|};
  accumulate_openai_payload acc st "[DONE]";
  match Complete_stream_acc.finalize_stream_acc acc with
  | Error (Types.Stream_incomplete { reason = "stream_terminal_without_stop_reason" }) ->
    true
  | Error _ | Ok _ -> false
;;

(* The [DONE] sentinel must not overwrite a real stop_reason that already
   arrived: a [finish_reason: "length"] chunk followed by [data: [DONE]] keeps
   MaxTokens (the sentinel only sets [done_sentinel_seen], which is ignored once
   a stop_reason was received). Guards against the helper turning every
   OpenAI-compat completion into EndTurn. *)
let%test
    "clean stream finalizes Ok: OpenAI-compat finish_reason:length then [DONE] keeps \
     MaxTokens"
  =
  let acc = Complete_stream_acc.create_stream_acc () in
  let st = Streaming.create_openai_stream_state ~provider:"openai" ~model:"m" () in
  accumulate_openai_payload
    acc
    st
    {|{"choices":[{"delta":{"content":"hi"},"finish_reason":"length"}]}|};
  accumulate_openai_payload acc st "[DONE]";
  match Complete_stream_acc.finalize_stream_acc acc with
  | Ok resp -> resp.stop_reason = Types.MaxTokens
  | Error _ -> false
;;

(* A provider error remains a typed provider-error event, never [MessageStop]
   or an empty result. The concrete constructor preserves the wire format. *)
let%test "OpenAI-compatible provider error result finalizes Error" =
  let acc = Complete_stream_acc.create_stream_acc () in
  let st = Streaming.create_openai_stream_state ~provider:"openai" ~model:"m" () in
  accumulate_openai_payload
    acc
    st
    {|{"error":{"type":"rate_limit_exceeded","message":"slow down"}}|};
  match Complete_stream_acc.finalize_stream_acc acc with
  | Error _ -> true
  | Ok _ -> false
;;

let complete_stream_http
      ~sw
      ~net
      ?clock
      ?latency_counter
      ?stream_idle_timeout_s
      ?first_event_timeout_s
      ?body_timeout_s
      ?observe_wire_chunk
      ?capture_id
      ?request_wire_observer
      ?admitted_body
      ?on_http_status
      ?(on_telemetry : (Telemetry_event.t -> unit) option)
      ?(metrics = Metrics.get_global ())
      ?(connection_cache : Http_client.cache option)
      ~(config : Provider_config.t)
      ~(messages : Types.message list)
      ~tools
      ~(on_event : Types.sse_event -> unit)
      ()
  =
  let validation =
    match admitted_body with
    | Some _ -> Ok ()
    | None -> validate_all config
  in
  let request =
    match validation with
    | Error _ as error -> error
    | Ok () ->
      Result.bind
        (match admitted_body with
         | None ->
           serialize_final_http_request_unadmitted ~stream:true ~config ~messages ~tools
         | Some admitted_body ->
           let evidence =
             Prepared_completion_request.admitted_body_evidence admitted_body
           in
           if evidence.stream
           then
             Ok
               ( Prepared_completion_request.admitted_body_http_codec admitted_body
               , Prepared_completion_request.admitted_body_contents admitted_body )
           else
             Error
               (Http_client.AcceptRejected
                  { reason =
                      "sync admitted body cannot be dispatched through the streaming path"
                  }))
        (fun (http_codec, body_str) ->
           match admitted_body with
           | Some _ -> Ok (http_codec, body_str)
           | None ->
             Result.map
               (fun final_body -> http_codec, final_body)
               (admit_final_serialized_body ~config body_str))
  in
  match request with
  | Error err -> Error err
  | Ok (http_codec, body_with_stream) ->
    if requires_non_http_transport config.kind
    then
      Error
        (Http_client.NetworkError
           { message =
               Printf.sprintf
                 "%s provider requires a transport"
                 (Provider_config.string_of_provider_kind config.kind)
           ; kind = Unknown
           })
    else (
      let url =
        match config.kind with
        | Provider_config.Gemini -> gemini_url ~config ~stream:true
        | Anthropic | Kimi | OpenAI_compat | Ollama | Glm | DashScope ->
          config.base_url ^ config.request_path
      in
      (match admitted_body with
       | Some admitted_body ->
         observe_pre_dispatch_serialization
           ?request_wire_observer
           (Prepared_completion_request.admitted_body_evidence admitted_body)
       | None ->
         observe_request_wire
           ?request_wire_observer
           ~capture_id
           ~config
           ~http_codec
           ~stream:true
           ~body:body_with_stream
           ());
      let requested_at = Unix.gettimeofday () in
      let latency_counter =
        match latency_counter with
        | Some counter -> counter
        | None -> start_latency_counter ?clock ()
      in
      let ttfrc_ref = ref None in
      (* RFC-OAS-020 — TTFT (Time To First Token) capture.
         [first_token_at_ref] fires on the first chunk that carries a
         non-empty generated delta (text / reasoning / tool-call arg).
         [first_event_at_ref] fires on the very first SSE
         event of any kind — used to derive [prefill_ms] when the
         provider exposes a separable prelude marker
         (e.g. Anthropic [MessageStart] arrives before the first
         [ContentBlockDelta]). *)
      let first_token_at_ref : float option ref = ref None in
      let first_event_at_ref : float option ref = ref None in
      (* Ollama-specific side channel: prompt_eval_count / eval_count and
     the four duration fields only appear on the [done:true] line, so
     stream_acc (which only sees content/tool deltas) cannot capture
     them. We trap them here and patch the finalised response below. *)
      let provider = Provider_config.string_of_provider_kind config.kind in
      let model = config.model_id in
      let active_wire_format =
        match http_codec with
        | Provider_http_codec.Ollama_chat -> Http_client.Ndjson
        | Anthropic_messages
        | Openai_chat
        | Openai_responses
        | Gemini_generate_content
        | Glm_chat -> Http_client.Sse
      in
      let on_response_status =
        let observe = Option.value ~default:metrics.on_http_status on_http_status in
        fun status -> observe ~provider ~model_id:model ~status
      in
      let emit_telemetry evt =
        record_streaming_metrics metrics evt;
        match on_telemetry with
        | Some f -> f evt
        | None -> ()
      in
      let ollama_usage = ref None in
      let ollama_timings = ref None in
      (* RFC-OAS-019 — stream-lifetime accumulators for the
         [Streaming_summary] variant that fires once at finalize.
         Hoisted out of [body_logic] so exception paths (timeout,
         transport error, SSE wire error) can publish too.
         [summary_published] makes publish_summary idempotent across
         all four paths. *)
      let first_chunk_seen = ref false in
      let chunk_counter = ref 0 in
      let last_chunk_t = ref None in
      let n_thinking = ref 0 in
      let n_answer = ref 0 in
      let n_tool_call_start = ref 0 in
      let n_tool_call_arg_delta = ref 0 in
      let n_tool_call_complete = ref 0 in
      let n_substrate = ref 0 in
      let n_heartbeat = ref 0 in
      let n_done = ref 0 in
      let inter_chunk_samples = ref [] in
      let terminal_state = ref Telemetry_event.Terminal_done in
      let summary_published = ref false in
      let stream_idle_state = ref Http_client.Awaiting_first_event in
      let classify_chunk_kind (evt : Types.sse_event) =
        match evt with
        | Types.MessageStart _ -> `Skip
        | Types.ContentBlockStart { content_type = "tool_use"; _ } -> `Tool_call_start
        | Types.ContentBlockStart _ -> `Substrate
        | Types.ContentBlockDelta { delta = TextDelta _; _ } -> `Answer
        | Types.ContentBlockDelta { delta = MediaDelta _; _ } -> `Answer
        | Types.ContentBlockDelta { delta = ThinkingDelta _; _ } -> `Thinking
        | Types.ContentBlockDelta { delta = ReasoningDetailsDelta _; _ } -> `Thinking
        | Types.ContentBlockDelta { delta = ThinkingSignatureDelta _; _ } -> `Substrate
        | Types.ContentBlockDelta { delta = InputJsonDelta _ | InputJsonSnapshot _; _ } ->
          `Tool_call_arg_delta
        | Types.ContentBlockStop _ -> `Tool_call_complete
        | Types.MessageDelta _ -> `Skip
        | Types.MessageStop -> `Done
        | Types.Ping -> `Heartbeat
        (* A provider-owned error envelope is NOT a wire failure: the response
           satisfied its contract and the provider reported a problem inside
           it. Classifying it as a wire error made the summary contradict the
           [Provider_reported_error] this stream actually returns. *)
        | Types.SSEError _ -> `Provider_reported_error
        | Types.NDJSONError _ -> `Provider_reported_error
        (* [SSEParseFailed] is emitted by format-agnostic producers — the
           Ollama (NDJSON) tool-routing path raises it via
           [Streaming.reject_tool_block ~protocol:"ollama"] — so the format
           comes from the stream, not from the variant's legacy name. *)
        | Types.SSEParseFailed _ -> `Wire_error active_wire_format
        (* Event types exist only in SSE; NDJSON has no event field. *)
        | Types.SSEUnknownEventType _ -> `Wire_error Http_client.Sse
        | Types.SSEUnsupportedPart _ -> `Capability_mismatch
        | Types.SSEUnsupportedResponse _ -> `Capability_mismatch
        | Types.NDJSONParseFailed _ -> `Wire_error Http_client.Ndjson
        | Types.Connected -> `Skip
        | Types.Timeout _ -> `Wire_error active_wire_format
        | Types.StreamIncomplete _ -> `Skip
      in
      let percentiles () =
        match !inter_chunk_samples with
        | [] -> None
        | samples ->
          let sorted = List.sort Float.compare samples in
          let n = List.length sorted in
          let nth k = List.nth sorted (max 0 (min (n - 1) k)) in
          let idx q = int_of_float (Float.of_int n *. q) in
          Some (nth (idx 0.5), nth (idx 0.95), nth (n - 1))
      in
      let publish_summary ~terminal () =
        if not !summary_published
        then (
          summary_published := true;
          let p50, p95, pmax =
            match percentiles () with
            | Some (p50, p95, pmax) -> Some p50, Some p95, Some pmax
            | None -> None, None, None
          in
          (* RFC-OAS-020: compute TTFT from first-token capture
             (was first-chunk = ttfrc). [prefill_ms] is the gap
             between any first event and the first token; [None]
             when they coincide (OpenAI-compat: no separable
             prelude). *)
          let ttft_ms =
            match !first_token_at_ref with
            | Some t -> Some t
            | None -> None
          in
          let prefill_ms =
            match !first_event_at_ref, !first_token_at_ref with
            | Some fe, Some ft when ft > fe -> Some fe
            | None, _ | Some _, None | Some _, Some _ -> None
          in
          emit_telemetry
            (Telemetry_event.Streaming_summary
               { provider
               ; model
               ; chunk_count = !chunk_counter
               ; kind_breakdown =
                   { thinking = !n_thinking
                   ; answer = !n_answer
                   ; tool_call_start = !n_tool_call_start
                   ; tool_call_arg_delta = !n_tool_call_arg_delta
                   ; tool_call_complete = !n_tool_call_complete
                   ; substrate = !n_substrate
                   ; heartbeat = !n_heartbeat
                   ; done_ = !n_done
                   }
               ; ttft_ms
               ; prefill_ms
               ; total_ms = latency_ms_float latency_counter
               ; inter_chunk_ms_p50 = p50
               ; inter_chunk_ms_p95 = p95
               ; inter_chunk_ms_max = pmax
               ; terminal
               }))
      in
      match
        Http_client.with_post_stream
          ?cache:connection_cache
          ?clock
          ?connect_timeout_s:config.connect_timeout_s
          ~on_response_status
          ~net
          ~url
          ~headers:(config.headers @ Provider_config.auth_headers_for_config config)
          ~body:body_with_stream
          ~f:(fun reader ->
            emit_stream_event on_event Types.Connected;
            (* OAS exposes one redacted provider observation to a caller-owned
               nonblocking offer. Queueing, persistence, capacity, and retries
               remain outside the provider SDK boundary. *)
            let observe_wire_chunk chunk =
              match observe_wire_chunk with
              | None -> ()
              | Some observe -> observe ~provider ~model ~chunk
            in
            let body_logic () =
              let acc = Complete_stream_acc.create_stream_acc () in
              let openai_state = ref None in
              let streaming_reasoning =
                (Reasoning_dialect.for_provider_config config).streaming
              in
              (* RFC-OAS-019: first_chunk_seen / chunk_counter / last_chunk_t
                 hoisted out of body_logic so publish_summary on
                 exception paths sees consistent state. *)
              let get_state () =
                match !openai_state with
                | Some s -> s
                | None ->
                  let s = Streaming.create_openai_stream_state ~provider ~model () in
                  openai_state := Some s;
                  s
              in
              let dispatch (events, tel_opt) =
                (* RFC-OAS-020: capture first-event + first-token
                   wall-clock offsets. [first_event_at_ref] fires on
                   ANY first event (prelude or token);
                   [first_token_at_ref] fires on generated token events,
                   including hidden reasoning. The two refs together
                   distinguish prefill from generation latency. *)
                let elapsed_ms = latency_ms_float latency_counter in
                if events <> []
                then (
                  (match elapsed_ms with
                   | Some elapsed_ms when Option.is_none !first_event_at_ref ->
                     first_event_at_ref := Some elapsed_ms
                   | Some _ | None -> ());
                  stream_idle_state := Http_client.Awaiting_first_delta);
                if
                  Option.is_none !first_token_at_ref
                  && List.exists Streaming.sse_event_is_first_token_signal events
                then first_token_at_ref := elapsed_ms;
                List.iter
                  (fun evt ->
                     emit_stream_event on_event evt;
                     Complete_stream_acc.accumulate_event acc evt;
                     (* RFC-OAS-019: classify each delta for the
                        [Streaming_summary] kind_breakdown that fires at
                        finalize. Wire errors set terminal_state; per-chunk
                        emission of [Streaming_chunk_n] is no longer
                        published — only the lifecycle summary is. *)
                     match classify_chunk_kind evt with
                     | `Skip -> ()
                     | `Thinking ->
                       stream_idle_state := Http_client.Streaming_thinking;
                       incr n_thinking
                     | `Answer ->
                       stream_idle_state := Http_client.Streaming_answer;
                       incr n_answer
                     | `Tool_call_start ->
                       stream_idle_state := Http_client.Streaming_tool_call;
                       incr n_tool_call_start
                     | `Tool_call_arg_delta ->
                       stream_idle_state := Http_client.Streaming_tool_call;
                       incr n_tool_call_arg_delta
                     | `Tool_call_complete ->
                       stream_idle_state := Http_client.Streaming_tool_call;
                       incr n_tool_call_complete
                     | `Substrate ->
                       stream_idle_state := Http_client.Streaming_substrate;
                       incr n_substrate
                     | `Heartbeat ->
                       stream_idle_state := Http_client.Streaming_heartbeat;
                       incr n_heartbeat
                     | `Done ->
                       stream_idle_state := Http_client.Streaming_done;
                       incr n_done
                     | `Wire_error format ->
                       stream_idle_state := Http_client.Streaming_unknown;
                       terminal_state
                       := Telemetry_event.Terminal_error
                            (Complete_stream_error.wire_error_terminal_label format)
                     | `Provider_reported_error ->
                       stream_idle_state := Http_client.Streaming_unknown;
                       terminal_state
                       := Telemetry_event.Terminal_error
                            Complete_stream_error.provider_reported_terminal_label
                     | `Capability_mismatch ->
                       stream_idle_state := Http_client.Streaming_unknown;
                       terminal_state
                       := Telemetry_event.Terminal_error
                            Complete_stream_error.capability_mismatch_terminal_label)
                  events;
                (* No thinking-only wall-clock cutoff: active reasoning
                     deltas ARE stream liveness. [stream_idle_timeout_s]
                     keeps its documented inter-event meaning (a stalled
                     socket still times out); bounding total turn duration
                     is the caller's contract, not the stream driver's
                     (38-bug campaign #10: the cutoff killed models that
                     legitimately think longer than the idle budget, and
                     retries re-ran and re-killed the round). *)
                if events <> []
                then
                  if not !first_chunk_seen
                  then (
                    first_chunk_seen := true;
                    (* Reuse the per-dispatch monotonic elapsed sample. This
                       keeps inter-chunk gaps measured dispatch-to-dispatch
                       instead of mixing in per-event processing time. *)
                    let ttfrc_ms = elapsed_ms in
                    ttfrc_ref := ttfrc_ms;
                    emit_telemetry
                      (Telemetry_event.Streaming_first_chunk
                         { provider; model; ttfrc_ms; requested_at });
                    last_chunk_t := elapsed_ms;
                    chunk_counter := 1)
                  else (
                    (* [elapsed_ms] is the dispatch-entry sample bound above.
                       [last_chunk_t] is also a dispatch-entry sample, so
                       [inter_chunk_ms] is a clean dispatch-to-dispatch gap. *)
                    (match elapsed_ms, !last_chunk_t with
                     | Some elapsed_ms, Some last_chunk_t ->
                       let inter_chunk_ms = elapsed_ms -. last_chunk_t in
                       (* RFC-OAS-019: per-chunk [Streaming_chunk_n] publish
                          removed. Inter-chunk gaps are accumulated for the
                          percentile reservoir in [Streaming_summary]. Metrics
                          sinks still receive the raw sample so aggregate backends
                          can preserve latency counters without re-expanding the
                          public telemetry stream. *)
                       metrics.on_streaming_chunk
                         ~provider
                         ~model_id:model
                         ~chunk_index:!chunk_counter
                         ~inter_chunk_ms;
                       inter_chunk_samples := inter_chunk_ms :: !inter_chunk_samples
                     | Some _, None | None, Some _ | None, None -> ());
                    last_chunk_t := elapsed_ms;
                    incr chunk_counter);
                match tel_opt with
                | Some evt -> emit_telemetry evt
                | None -> ()
              in
              let stream_read_result =
                try
                  (match http_codec with
                   | Provider_http_codec.Ollama_chat ->
                     Http_client.read_ndjson
                       ?clock
                       ?idle_timeout:stream_idle_timeout_s
                       ?first_event_timeout:first_event_timeout_s
                       ?body_timeout:body_timeout_s
                       ~reader
                       ~on_line:(fun line ->
                         observe_wire_chunk line;
                         if not (Complete_stream_acc.stream_failed acc)
                         then (
                           match Streaming.parse_ollama_ndjson_chunk line with
                           | Streaming.Ollama_parse_failed { raw; reason } ->
                             dispatch ([ Types.NDJSONParseFailed { raw; reason } ], None)
                           | Streaming.Ollama_provider_error { message; error_type; raw }
                             ->
                             dispatch
                               ([ Types.NDJSONError { message; error_type; raw } ], None)
                           | Streaming.Ollama_chunk chunk ->
                             (match chunk.oll_timings with
                              | Some _ as t -> ollama_timings := t
                              | None -> ());
                             (match chunk.oll_usage with
                              | Some _ as u -> ollama_usage := u
                              | None -> ());
                             dispatch
                               (Streaming.ollama_chunk_to_events (get_state ()) chunk)))
                       ()
                   | _non_ollama_kind ->
                     Http_client.read_sse
                       ?clock
                       ?idle_timeout:stream_idle_timeout_s
                       ?first_event_timeout:first_event_timeout_s
                       ?body_timeout:body_timeout_s
                       ~reader
                       ~on_data:(fun ~event_type data ->
                         observe_wire_chunk data;
                         if not (Complete_stream_acc.stream_failed acc)
                         then (
                           let events =
                             match http_codec with
                             | Provider_http_codec.Anthropic_messages ->
                               (match Streaming.parse_sse_event event_type data with
                                | Some evt -> [ evt ], None
                                | None ->
                                  ( [ Types.SSEParseFailed
                                        { raw = data
                                        ; reason =
                                            "anthropic_sse_parser_returned_no_event"
                                        }
                                    ]
                                  , None ))
                             | Provider_http_codec.Openai_responses ->
                               Streaming.responses_sse_to_events
                                 (get_state ())
                                 event_type
                                 data
                             | Provider_http_codec.Openai_chat ->
                               Streaming.parse_openai_sse_chunk ~streaming_reasoning data
                               |> Streaming.openai_sse_parse_result_to_events
                                    (get_state ())
                             | Provider_http_codec.Gemini_generate_content ->
                               (match Streaming.parse_gemini_sse_chunk data with
                                | Streaming.Gemini_chunk chunk ->
                                  (match
                                     Streaming.gemini_chunk_to_events (get_state ()) chunk
                                   with
                                   | Ok events -> events
                                   | Error { reason } ->
                                     [ Types.SSEParseFailed { raw = data; reason } ], None)
                                | Streaming.Gemini_parse_failed { reason; raw } ->
                                  [ Types.SSEParseFailed { raw; reason } ], None
                                | Streaming.Gemini_unsupported_part { part; raw } ->
                                  ( [ Types.SSEUnsupportedPart
                                        { provider_kind = Provider_kind.Gemini
                                        ; part =
                                            Streaming.gemini_unsupported_part_wire_name
                                              part
                                        ; raw
                                        }
                                    ]
                                  , None )
                                | Streaming.Gemini_unsupported_response { response; raw }
                                  ->
                                  ( [ Types.SSEUnsupportedResponse
                                        { provider_kind = Provider_kind.Gemini
                                        ; response =
                                            Streaming
                                            .gemini_unsupported_response_wire_name
                                              response
                                        ; raw
                                        }
                                    ]
                                  , None ))
                             | Provider_http_codec.Glm_chat ->
                               Backend_glm.parse_stream_chunk ~streaming_reasoning data
                               |> Streaming.openai_sse_parse_result_to_events
                                    (get_state ())
                             | Provider_http_codec.Ollama_chat ->
                               [], None (* unreachable: handled above *)
                           in
                           dispatch events))
                       ());
                  Ok ()
                with
                (* Typed at the boundary rather than routed through
                   [SSEParseFailed]: an oversized payload is not malformed
                   syntax, and encoding the sizes into a [reason] string would
                   hand downstream a classification it has to re-parse. *)
                | Http_client.Sse_event_too_large { actual_bytes; limit_bytes } ->
                  terminal_state
                  := Telemetry_event.Terminal_error
                       (Http_client.provider_wire_format_to_string active_wire_format
                        ^ "_wire_error");
                  Error
                    (Complete_stream_error.http_error_of_oversized_payload
                       ~wire_format:active_wire_format
                       ~actual_bytes:(Some actual_bytes)
                       ~limit_bytes)
                (* The same policy one level down: a single line larger than
                   the buffered reader's [max_size]. Both formats reach here —
                   [read_ndjson] has no accumulator, so an oversized NDJSON
                   line can only surface this way, and it used to escape
                   unclassified. *)
                | Eio.Buf_read.Buffer_limit_exceeded ->
                  terminal_state
                  := Telemetry_event.Terminal_error
                       (Http_client.provider_wire_format_to_string active_wire_format
                        ^ "_wire_error");
                  Error
                    (Complete_stream_error.http_error_of_oversized_payload
                       ~wire_format:active_wire_format
                       ~actual_bytes:None
                       ~limit_bytes:Api_common.max_response_body)
                | Eio.Time.Timeout when Complete_stream_acc.stream_failed acc -> Ok ()
                | Eio.Time.Timeout ->
                  let phase =
                    Http_client.timeout_phase_of_stream_idle_state !stream_idle_state
                  in
                  (* RFC-OAS-037: name the knob that actually armed this
                     deadline. Before the TTFT split every phase was governed
                     by stream_idle_timeout_s; now a first-event timeout can
                     come from first_event_timeout_s or body_timeout_s, and
                     naming the idle knob would send the operator to tune a
                     value that had no effect on the phase that failed. *)
                  let governing_knob =
                    Http_client.timeout_knob_to_param
                      (Http_client.governing_timeout_knob
                         ~state:!stream_idle_state
                         ~first_event_timeout:first_event_timeout_s
                         ~body_timeout:body_timeout_s
                         ~idle_timeout:stream_idle_timeout_s)
                  in
                  let message =
                    Printf.sprintf
                      "%s deadline exceeded while %s"
                      governing_knob
                      (Http_client.stream_idle_state_to_label !stream_idle_state)
                  in
                  emit_stream_event on_event (Types.Timeout message);
                  emit_telemetry
                    (Telemetry_event.Timeout
                       { provider
                       ; model
                       ; timeout_type = Telemetry_event.Stream_idle !stream_idle_state
                       });
                  publish_summary
                    ~terminal:
                      (Telemetry_event.Terminal_error
                         (Printf.sprintf
                            "%s_exceeded:%s"
                            governing_knob
                            (Http_client.stream_idle_state_to_label !stream_idle_state)))
                    ();
                  Error (Http_client.TimeoutError { message; phase })
              in
              match stream_read_result with
              | Error _ as err -> err
              | Ok () ->
                let result =
                  match Complete_stream_acc.finalize_stream_acc acc with
                  | Ok _ as ok -> ok
                  | Error serr ->
                    (match !terminal_state with
                     | Telemetry_event.Terminal_done ->
                       terminal_state
                       := Telemetry_event.Terminal_error
                            (match serr with
                             | Types.Stream_provider_error _ ->
                               Complete_stream_error.provider_reported_terminal_label
                             | Types.Stream_parse_failed _
                             | Types.Stream_ndjson_parse_failed _
                             | Types.Stream_unknown_event _
                             | Types.Stream_incomplete _ ->
                               Complete_stream_error.wire_error_terminal_label
                                 active_wire_format
                             | Types.Stream_unsupported_part _
                             | Types.Stream_unsupported_response _ ->
                               Complete_stream_error.capability_mismatch_terminal_label)
                     | Telemetry_event.Terminal_error _
                     | Telemetry_event.Terminal_cancelled -> ());
                    Error
                      (Complete_stream_error.http_error_of_stream_error
                         ~wire_format:active_wire_format
                         serr)
                in
                (* RFC-OAS-019: emit one [Streaming_summary] at stream
                   finalize on the normal path. [terminal_state] defaults to
                   [Terminal_done]; dispatch and finalize errors upgrade it
                   before publication. *)
                publish_summary ~terminal:!terminal_state ();
                result
            in
            body_logic ())
          ()
      with
      | Error _ as e ->
        (* RFC-OAS-019: transport-level error before body_logic ran (or
           before its publish). Idempotent via summary_published. *)
        publish_summary ~terminal:(Telemetry_event.Terminal_error "transport_error") ();
        e
      | Ok (Ok resp) ->
        let latency_ms = latency_ms_int latency_counter in
        (* Ollama injection: usage from the done chunk wins over the
         zeroed accumulator, and timings populate the otherwise-None
         telemetry slot before patch_telemetry layers in latency. *)
        let resp =
          match config.kind with
          | Provider_config.Ollama ->
            let usage =
              match !ollama_usage with
              | Some _ as u -> u
              | None -> resp.usage
            in
            let telemetry =
              match resp.telemetry, !ollama_timings with
              | _, None -> resp.telemetry
              | Some t, (Some _ as timings) -> Some { t with timings }
              | None, (Some _ as timings) ->
                Some { Types.default_inference_telemetry with timings }
            in
            { resp with usage; telemetry }
          | Anthropic | Kimi | OpenAI_compat | Gemini | Glm | DashScope -> resp
        in
        (match !ollama_timings with
         | Some
             { Types.prompt_n = Some prompt_eval_tokens
             ; prompt_ms = Some prompt_eval_ms
             ; cache_n
             ; _
             } ->
           let cache_hit =
             match cache_n with
             | Some n when n > 0 -> true
             | Some _ | None -> false
           in
           emit_telemetry
             (Telemetry_event.Prefill_complete
                { provider; model; prompt_eval_tokens; prompt_eval_ms; cache_hit })
         | Some _ | None -> ());
        let prefill_ms = Option.bind !ollama_timings (fun t -> t.prompt_ms) in
        Ok (patch_telemetry resp ~config ~ttfrc_ms:!ttfrc_ref ~prefill_ms latency_ms)
      | Ok (Error (Http_client.TimeoutError _ as err)) ->
        publish_summary ~terminal:(Telemetry_event.Terminal_error "timeout_error") ();
        Error err
      | Ok (Error err) ->
        (* oas#2947: a glm request rejection arrives as a non-200 whose body is
           glm's structured error envelope. Promote a code-1261 context
           overflow to the typed [ProviderFailure Context_overflow] here, while
           the provider identity is still known — downstream classification
           ([Retry.classify_error]) is provider-agnostic and would flatten it
           into [InvalidRequest Unknown_invalid_request], cutting consumers off
           from their compaction/shrink recovery. The promotion parses the
           envelope's documented [code] field ([Backend_glm.check_glm_error]),
           never message prose. *)
        let err =
          match http_codec with
          | Provider_http_codec.Glm_chat ->
            (match err with
             | Http_client.HttpError { body; _ } ->
               (match Backend_glm.check_glm_error body with
                | Some
                    { Backend_glm.error_class = Backend_glm.Glm_context_overflow
                    ; message
                    ; _
                    } ->
                  Http_client.ProviderFailure
                    { kind = Http_client.Context_overflow { limit = None }; message }
                | Some _ | None -> err)
             | Http_client.NetworkError _
             | Http_client.TimeoutError _
             | Http_client.AcceptRejected _
             | Http_client.ProviderTerminal _
             | Http_client.ProviderFailure _ -> err)
          | Provider_http_codec.Anthropic_messages
          | Provider_http_codec.Openai_chat
          | Provider_http_codec.Openai_responses
          | Provider_http_codec.Gemini_generate_content
          | Provider_http_codec.Ollama_chat -> err
        in
        let terminal =
          match !terminal_state with
          | (Telemetry_event.Terminal_error _ | Telemetry_event.Terminal_cancelled) as
            terminal -> terminal
          | Telemetry_event.Terminal_done ->
            Telemetry_event.Terminal_error
              (Printf.sprintf
                 "%s_stream_error: %s"
                 (Http_client.provider_wire_format_to_string active_wire_format)
                 (match err with
                  | Http_client.NetworkError { message; _ }
                  | Http_client.TimeoutError { message; _ } -> message
                  | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
                  | Http_client.AcceptRejected { reason } -> reason
                  | Http_client.ProviderTerminal { message; _ } -> message
                  | Http_client.ProviderFailure { message; _ } -> message))
        in
        publish_summary ~terminal ();
        Error err)
;;
