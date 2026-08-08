(** Standalone LLM completion: build -> HTTP -> parse.

    Self-contained in llm_provider -- no agent_sdk dependency.
    Consumers can call these functions directly.

    @since 0.46.0  Sync completion
    @since 0.53.0  Streaming
    @since 0.54.0  Optional cache + metrics hooks *)

open Complete_common
open Complete_sync
open Complete_stream

type latency_counter = Complete_common.latency_counter
type prepared_request = Prepared_completion_request.t
type serialized_request = Prepared_completion_request.serialized
type measured_request = Prepared_completion_request.measured
type admitted_request = Prepared_completion_request.admitted

type context_fit = Prepared_completion_request.context_fit =
  { input_tokens : int
  ; reserved_output_tokens : int
  ; max_context_tokens : int
  }

type fit_error = Prepared_completion_request.fit_error =
  | Context_limit_unknown of { model_id : string }
  | Invalid_context_limit of
      { model_id : string
      ; max_context_tokens : int
      }
  | Output_reservation_unknown of { model_id : string }
  | Context_window_exceeded of context_fit
  | Serving_constraint_rejected of
      { constraint_ : Serving_constraint.t
      ; reason : Serving_constraint.admission_error
      }

let prepare_request = Prepared_completion_request.prepare
let admit_request_body = Prepared_completion_request.admit_serialized_body
let measure_request = Prepared_completion_request.measure
let resolve_context_limit = Prepared_completion_request.resolve_context_limit
let requires_token_measurement = Prepared_completion_request.requires_token_measurement
let serving_constraint = Prepared_completion_request.serving_constraint
let admit_request = Prepared_completion_request.admit
let admitted_fit = Prepared_completion_request.admitted_fit

let inspect_serialized_request
      ~stream
      ~(config : Provider_config.t)
      ~(messages : Types.message list)
      ?(tools = [])
      ()
  =
  Result.bind (validate_all config) (fun () ->
    Result.map
      (fun (http_codec, body) ->
         Request_wire_observer.observation
           ~capture_id:None
           ~provider:(Provider_registry.provider_name_of_config config)
           ~model:config.model_id
           ~http_codec:(Provider_http_codec.fingerprint_tag http_codec)
           ~stream
           ~body)
      (serialize_final_http_request_unadmitted ~stream ~config ~messages ~tools))
;;

let complete_prepared_sync
      ~sw
      ~net
      ?clock
      ?(transport : Llm_transport.t option)
      ~(prepared : Prepared_completion_request.t)
      ?(cache : Cache.t option)
      ?(connection_cache : Http_client.cache option)
      ?(metrics : Metrics.t option)
      ?body_timeout_s
      ?request_wire_observer
      ?admitted_body
      ()
  =
  let request = Prepared_completion_request.request prepared in
  let request =
    match request_wire_observer with
    | None -> request
    | Some request_wire_observer ->
      { request with request_wire_observer = Some request_wire_observer }
  in
  let config = request.Llm_transport.config in
  let messages = request.messages in
  let tools = request.tools in
  let validation =
    match admitted_body, transport with
    | Some _, None -> Ok ()
    | None, _ | Some _, Some _ -> validate_all config
  in
  let preflight =
    match validation with
    | Error err -> Error err
    | Ok () ->
      Http_client.resolve_explicit_deadline
        ~operation:"Complete.complete"
        ~parameter:"body_timeout_s"
        ~clock
        ~timeout_s:body_timeout_s
  in
  match preflight with
  | Error err -> Error err
  | Ok body_deadline ->
    let m =
      match metrics with
      | Some m -> m
      | None -> Metrics.get_global ()
    in
    let model_id = config.model_id in
    let request_config = config in
    (* Cache lookup *)
    (* Compute fingerprint once; reuse for both lookup and store *)
    let cache_key =
      match cache with
      | Some _ -> Some (Cache.request_fingerprint ~config ~messages ~tools ())
      | None -> None
    in
    let cached =
      match cache, cache_key with
      | Some c, Some key ->
        (match c.get ~key with
         | Some json ->
           (match Cache.response_of_json json with
            | Some resp ->
              m.on_cache_hit ~model_id;
              Some (Ok resp)
            | None ->
              m.on_cache_miss ~model_id;
              None)
         | None ->
           m.on_cache_miss ~model_id;
           None)
      | _, _ -> None
    in
    (match cached with
     | Some result -> ensure_nonempty_completion result
     | None ->
       m.on_request_start ~model_id;
       let dispatch () =
         match transport with
         | Some t ->
           let run_transport () = t.complete_sync request in
           (match body_deadline with
            | Http_client.Unbounded ->
              Http_client.with_explicit_deadline body_deadline run_transport
            | Http_client.Bounded (clock, timeout_s) ->
              (match
                 Eio.Time.with_timeout clock timeout_s (fun () -> Ok (run_transport ()))
               with
               | Ok result -> result
               | Error `Timeout ->
                 { Llm_transport.response =
                     Error
                       (Http_client.TimeoutError
                          { message =
                              Printf.sprintf
                                "body_timeout_s deadline exceeded after %.17gs \
                                 (Complete.complete injected sync transport)"
                                timeout_s
                          ; phase = Http_client.Non_streaming_body
                          })
                 ; latency_ms = None
                 }))
         | None ->
           let resp, lat =
             complete_http
               ~sw
               ~net
               ?clock
               ~on_http_status:m.on_http_status
               ?body_timeout_s
               ?connection_cache
               ?capture_id:request.capture_id
               ?request_wire_observer:request.request_wire_observer
               ?admitted_body
               ~config:request_config
               ~messages
               ~tools
               ()
           in
           { Llm_transport.response = resp; latency_ms = lat }
       in
       let { Llm_transport.response = result; latency_ms } =
         (* The permit spans the full provider round-trip; cache hits above
            never take one. Waiting for a permit is queueing, not part of the
            provider interaction, so body_timeout_s does not cover it. *)
         Provider_admission.with_admission ~config:request_config dispatch
       in
       (* HTTP-backed transports bypass complete_http, so emit the status
         here using the transport result. Non-HTTP CLI transports must
         stay silent because they never observed an HTTP status code. *)
       if Option.is_some transport && not (requires_non_http_transport config.kind)
       then (
         match result with
         | Ok _ ->
           m.on_http_status
             ~provider:(Provider_registry.provider_name_of_config config)
             ~model_id
             ~status:200
         | Error (Http_client.HttpError { code; _ }) ->
           m.on_http_status
             ~provider:(Provider_registry.provider_name_of_config config)
             ~model_id
             ~status:code
         | Error _ -> ());
       let result = ensure_nonempty_completion result in
       (match result with
        | Ok resp ->
          let resp =
            Pricing.annotate_response_cost ?provider_id:config.provider_id resp
          in
          let resp = patch_telemetry resp ~config latency_ms in
          m.on_request_end ~model_id ~latency_ms;
          emit_tool_call_metrics
            m
            ~provider:(Provider_registry.provider_name_of_config config)
            ~model_id
            resp;
          (match resp.usage with
           | Some u ->
             m.on_token_usage
               ~provider:(Provider_registry.provider_name_of_config config)
               ~model_id
               ~input_tokens:u.input_tokens
               ~output_tokens:u.output_tokens
           | None -> ());
          (* Cache store — reuse pre-computed key *)
          (match cache, cache_key with
           | Some c, Some key ->
             let json = Cache.response_to_json resp in
             (try c.set ~key ~ttl_sec:Constants.Cache.default_ttl_sec json with
              | (Eio.Io _ | Sys_error _) as exn ->
                Diag.warn
                  "complete"
                  "cache set failed for key %s: %s"
                  key
                  (Printexc.to_string exn))
           | _, _ -> ());
          Ok resp
        | Error err ->
          let err_str =
            match err with
            | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
            | Http_client.AcceptRejected { reason } -> reason
            | Http_client.NetworkError { message; _ } -> message
            | Http_client.TimeoutError { message; _ } -> message
            | Http_client.ProviderTerminal { message; _ } -> message
            | Http_client.ProviderFailure { kind; message } ->
              Http_client.provider_failure_to_string ~kind ~message
          in
          m.on_error ~model_id ~error:err_str;
          Error err))
;;

let complete
      ~sw
      ~net
      ?clock
      ?transport
      ~(config : Provider_config.t)
      ~(messages : Types.message list)
      ?(tools = [])
      ?(trace_context = [])
      ?cache
      ?connection_cache
      ?metrics
      ?body_timeout_s
      ?capture_id
      ?request_wire_observer
      ()
  =
  let prepared = prepare_request ~config ~messages ~tools ~trace_context ?capture_id () in
  complete_prepared_sync
    ~sw
    ~net
    ?clock
    ?transport
    ~prepared
    ?cache
    ?connection_cache
    ?metrics
    ?body_timeout_s
    ?request_wire_observer
    ()
;;

let complete_admitted
      ~sw
      ~net
      ?clock
      ?transport
      admitted
      ?cache
      ?connection_cache
      ?metrics
      ?body_timeout_s
      ?request_wire_observer
      ()
  =
  let admitted_body = Prepared_completion_request.admitted_body admitted in
  complete_prepared_sync
    ~sw
    ~net
    ?clock
    ?transport
    ~prepared:(Prepared_completion_request.admitted_request admitted)
    ?admitted_body
    ?cache
    ?connection_cache
    ?metrics
    ?body_timeout_s
    ?request_wire_observer
    ()
;;

(* ── Streaming ───────────────────────────────────────── *)

let complete_prepared_stream
      ~sw
      ~net
      ?clock
      ?(transport : Llm_transport.t option)
      ?wire_observer
      ?request_wire_observer
      ?admitted_body
      ~(prepared : Prepared_completion_request.t)
      ~(on_event : Types.sse_event -> unit)
      ?metrics
      ?(connection_cache : Http_client.cache option)
      ?(on_telemetry : (Telemetry_event.t -> unit) option)
      ()
  =
  let request = Prepared_completion_request.request prepared in
  let config = request.Llm_transport.config in
  let messages = request.messages in
  let tools = request.tools in
  let validation =
    match admitted_body, transport with
    | Some _, None -> Ok ()
    | None, _ | Some _, Some _ -> validate_all config
  in
  match validation with
  | Error err -> Error err
  | Ok () ->
    let on_event = emit_stream_event on_event in
    let request_config = config in
    let latency_counter = start_latency_counter ?clock () in
    let metrics_opt = metrics in
    let metrics = Option.value metrics ~default:(Metrics.get_global ()) in
    let on_telemetry_with_metrics evt =
      record_streaming_metrics metrics evt;
      match on_telemetry with
      | Some f -> f evt
      | None -> ()
    in
    let transport_on_telemetry =
      match metrics_opt, on_telemetry with
      | None, None -> None
      | Some _, _ | None, Some _ -> Some on_telemetry_with_metrics
    in
    let emit_wire_observer_failure failure =
      let event = Telemetry_event.Wire_observer_failure failure in
      try
        record_streaming_metrics metrics event;
        match on_telemetry with
        | Some emit -> emit event
        | None ->
          Diag.warn
            "wire_observer"
            "wire observation was not accepted and no telemetry callback is installed: %s"
            (Wire_observer.show_failure failure)
      with
      | exn ->
        Reserved_exn.reraise_if_reserved exn;
        (* Observation diagnostics must not rewrite a completed provider
           interaction as a provider failure. The original typed failure and
           telemetry callback exception both remain visible here. *)
        Diag.warn
          "wire_observer"
          "wire observer failure telemetry callback raised: %s; original=%s"
          (Printexc.to_string exn)
          (Wire_observer.show_failure failure)
    in
    let request =
      let request =
        match request_wire_observer with
        | None -> request
        | Some request_wire_observer ->
          { request with request_wire_observer = Some request_wire_observer }
      in
      match wire_observer with
      | None -> request
      | Some try_observe ->
        let observe_wire_chunk ~provider ~model ~chunk =
          match
            Wire_observer.observe
              try_observe
              ~capture_id:request.capture_id
              ~provider
              ~model
              ~chunk
          with
          | Ok () -> ()
          | Error failure -> emit_wire_observer_failure failure
        in
        { request with observe_wire_chunk = Some observe_wire_chunk }
    in
    (* The transport arm below never reaches [complete_stream_http]'s own
       status wiring, so the sink travels with the request — the same way
       [observe_wire_chunk] does. An HTTP-backed transport reports what it
       observed; a CLI transport ignores the field and stays silent. *)
    let request = { request with observe_http_status = Some metrics.on_http_status } in
    let dispatch () =
      match transport with
      | Some t -> t.complete_stream ?on_telemetry:transport_on_telemetry ~on_event request
      | None ->
        complete_stream_http
          ~sw
          ~net
          ?clock
          ?stream_idle_timeout_s:request.stream_idle_timeout_s
          ?first_event_timeout_s:request.first_event_timeout_s
          ?body_timeout_s:request.body_timeout_s
          ?observe_wire_chunk:request.observe_wire_chunk
          ?capture_id:request.capture_id
          ?request_wire_observer:request.request_wire_observer
          ?admitted_body
          ~on_http_status:metrics.on_http_status
          ~latency_counter
          ?on_telemetry
          ~metrics
          ?connection_cache
          ~config:request_config
          ~messages
          ~tools
          ~on_event
          ()
    in
    let result =
      (* The permit spans the entire stream: the provider holds the
         connection open until the final SSE event, so concurrency
         accounting must too. *)
      Provider_admission.with_admission ~config:request_config dispatch
    in
    Result.map
      (fun resp ->
         let latency_ms = latency_ms_int latency_counter in
         let resp = Pricing.annotate_response_cost ?provider_id:config.provider_id resp in
         let existing_telemetry = resp.telemetry in
         let ttfrc_ms = Option.bind existing_telemetry (fun t -> t.ttfrc_ms) in
         let prefill_ms = Option.bind existing_telemetry (fun t -> t.prefill_ms) in
         let resp = patch_telemetry resp ~config ~ttfrc_ms ~prefill_ms latency_ms in
         emit_tool_call_metrics
           metrics
           ~provider:(Provider_registry.provider_name_of_config config)
           ~model_id:config.model_id
           resp;
         resp)
      (ensure_nonempty_completion result)
;;

let complete_stream
      ~sw
      ~net
      ?clock
      ?stream_idle_timeout_s
      ?first_event_timeout_s
      ?body_timeout_s
      ?transport
      ?capture_id
      ?wire_observer
      ?request_wire_observer
      ~(config : Provider_config.t)
      ~(messages : Types.message list)
      ?(tools = [])
      ?(trace_context = [])
      ~on_event
      ?metrics
      ?connection_cache
      ?on_telemetry
      ()
  =
  let prepared =
    prepare_request
      ~config
      ~messages
      ~tools
      ~trace_context
      ?capture_id
      ?stream_idle_timeout_s
      ?first_event_timeout_s
      ?body_timeout_s
      ()
  in
  complete_prepared_stream
    ~sw
    ~net
    ?clock
    ?transport
    ?wire_observer
    ?request_wire_observer
    ~prepared
    ~on_event
    ?metrics
    ?connection_cache
    ?on_telemetry
    ()
;;

let complete_stream_admitted
      ~sw
      ~net
      ?clock
      ?transport
      ?wire_observer
      ?request_wire_observer
      admitted
      ~on_event
      ?metrics
      ?connection_cache
      ?on_telemetry
      ()
  =
  let admitted_body = Prepared_completion_request.admitted_body admitted in
  complete_prepared_stream
    ~sw
    ~net
    ?clock
    ?transport
    ?wire_observer
    ?request_wire_observer
    ~prepared:(Prepared_completion_request.admitted_request admitted)
    ?admitted_body
    ~on_event
    ?metrics
    ?connection_cache
    ?on_telemetry
    ()
;;

(* ── HTTP Transport constructor ─────────────────────── *)

let make_http_transport
      ?clock
      ?body_timeout_s
      ?(connection_cache : Http_client.cache option)
      ?latency_counter
      ~sw
      ~net
      ()
  : Llm_transport.t
  =
  { complete_sync =
      (fun (req : Llm_transport.completion_request) ->
        let response, latency_ms =
          complete_http
            ~sw
            ~net
            ?clock
            ?body_timeout_s
            ?connection_cache
            ?capture_id:req.capture_id
            ?request_wire_observer:req.request_wire_observer
            ~config:req.config
            ~messages:req.messages
            ~tools:req.tools
            ()
        in
        { Llm_transport.response; latency_ms })
  ; complete_stream =
      (fun ?on_telemetry ~on_event (req : Llm_transport.completion_request) ->
        complete_stream_http
          ~sw
          ~net
          ?clock
          ?on_http_status:req.observe_http_status
          ?stream_idle_timeout_s:req.stream_idle_timeout_s
          ?first_event_timeout_s:req.first_event_timeout_s
          ?body_timeout_s:req.body_timeout_s
          ?observe_wire_chunk:req.observe_wire_chunk
          ?capture_id:req.capture_id
          ?request_wire_observer:req.request_wire_observer
          ?connection_cache
          ?latency_counter
          ~config:req.config
          ~messages:req.messages
          ~tools:req.tools
          ~on_event
          ?on_telemetry
          ())
  }
;;
