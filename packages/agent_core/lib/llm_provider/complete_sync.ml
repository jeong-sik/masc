(** Synchronous HTTP completion implementation.

    Extracted from {!Complete} to keep the entry-point module
    focused on orchestration and retry logic.

    @since 0.205.9 *)

include Complete_common
include Complete_sampling

let non_streaming_body_timeout timeout_s =
  Http_client.TimeoutError
    { message =
        Printf.sprintf
          "body_timeout_s deadline exceeded after %.1fs (Complete.complete non-streaming \
           path; total HTTP round-trip cap)"
          timeout_s
    ; phase = Http_client.Non_streaming_body
    }
;;

type 'a body_deadline_outcome =
  | Body_completed of 'a
  | Body_deadline_exceeded of float

let run_with_body_deadline body_deadline f =
  match body_deadline with
  | Http_client.Unbounded -> Body_completed (f ())
  | Http_client.Bounded (clock, timeout_s) ->
    (match Under_deadline.run clock timeout_s f with
     | Ok result -> Body_completed result
     | Error `Timeout -> Body_deadline_exceeded timeout_s)
;;

let%test "run_with_body_deadline does not relabel a nested timeout exception" =
  Eio_main.run
  @@ fun env ->
  (* Any positive budget: [f] raises before the deadline is ever read. *)
  match
    Http_client.resolve_explicit_deadline
      ~operation:"run_with_body_deadline"
      ~parameter:"body_timeout_s"
      ~clock:(Some (Eio.Stdenv.clock env))
      ~timeout_s:(Some 1.0)
  with
  | Ok deadline ->
    (match run_with_body_deadline deadline (fun () -> raise Eio.Time.Timeout) with
     | exception Eio.Time.Timeout -> true
     | (exception _) | Body_completed _ | Body_deadline_exceeded _ -> false)
  (* A refused budget is the resolver's failure, not a relabeling one: say so
     rather than report it under this test's name with no reason. *)
  | Error (Http_client.AcceptRejected { reason }) -> failwith reason
  | Error _ -> failwith "run_with_body_deadline: the test deadline was refused"
;;

let provider_parse_failure ?parser message =
  Error
    (Http_client.ProviderFailure
       { kind = Http_client.Provider_parse_error { parser }; message })
;;

(** Parse one successful HTTP response using only the frozen wire codec and
    provider kind. This function performs no request serialization, provider
    lookup, pricing lookup, dispatch, or retry.

    [content_inline_reasoning] is the caller-resolved catalog contract for
    reasoning embedded in the content channel; it reaches the
    OpenAI-compatible and GLM chat codecs, whose sync parser can split it. *)
let parse_sync_response
      ?(content_inline_reasoning = Capabilities.No_content_inline_reasoning)
      ~http_codec
      ~provider_kind
      body
  =
  try
    match http_codec with
    | Provider_http_codec.Anthropic_messages ->
      Ok (Backend_anthropic.parse_response (Yojson.Safe.from_string body))
    | Provider_http_codec.Ollama_chat ->
      (match Backend_ollama.parse_ollama_response ~content_inline_reasoning body with
       | Ok response -> Ok response
       | Error message ->
         Error
           (Http_client.HttpError
              { code = 400; body = Http_client.Received message; retry_after_header = None }))
    | Provider_http_codec.Openai_responses ->
      (match Backend_openai_responses.parse_response_result body with
       | Ok response -> Ok response
       | Error message ->
         Error
           (Http_client.HttpError
              { code = 400; body = Http_client.Received message; retry_after_header = None }))
    | Provider_http_codec.Openai_chat ->
      (match
         Backend_openai_parse.parse_openai_response_result
           ~content_inline_reasoning
           body
       with
       | Ok response -> Ok response
       (* The same reading as the streaming path
          ([Complete_stream_error.http_error_of_stream_error]): a 429 or 5xx
          the error object declared inside the 200 is the refusal that status
          line would have been, classified from the error object alone; any
          other provider-reported error is provider-owned diagnostic data. *)
       | Error
           (Backend_openai_parse.Provider_error
             { provider_status = Some { Types.status; error_body }
             ; message = _
             ; error_type = _
             ; report = _
             }) ->
         Error
           (Http_client.HttpError
              { code = status
              ; body = Http_client.Received error_body
              ; retry_after_header = None
              })
       | Error
           (Backend_openai_parse.Provider_error
             { provider_status = None
             ; message
             ; error_type
             ; report = Types.Provider_stated
             }) ->
         Error
           (Http_client.ProviderFailure
              { kind = Http_client.Provider_reported_error { error_type }; message })
       (* The choice said the generation failed and the response carried no
          error object: there is no envelope to read a type or a status from,
          and the answer stopped part-way for a reason the provider kept to
          itself. *)
       | Error
           (Backend_openai_parse.Provider_error
             { provider_status = None
             ; message
             ; error_type = _
             ; report = Types.Unstated_errored_choice
             }) ->
         Error
           (Http_client.ProviderFailure { kind = Http_client.Provider_interrupted; message })
       | Error (Backend_openai_parse.Unreadable_response message) ->
         provider_parse_failure
           ~parser:(Provider_config.string_of_provider_kind provider_kind)
           message
       | Error (Backend_openai_parse.Empty_completion empty) ->
         Error (Http_client.empty_completion_error ~stop_reason:empty.stop_reason))
    | Provider_http_codec.Gemini_generate_content ->
      Ok (Backend_gemini.parse_response (Yojson.Safe.from_string body))
    | Provider_http_codec.Glm_chat ->
      (match Backend_glm.parse_response_result ~content_inline_reasoning body with
       | Ok response -> Ok response
       | Error (Backend_openai_parse.Empty_completion empty) ->
         Error (Http_client.empty_completion_error ~stop_reason:empty.stop_reason)
       (* glm reports its own errors through [check_glm_error_json] (raised as
          [Glm_api_error] below); an error the OpenAI-compatible reader finds
          after that stays a glm parse failure, as it always has. *)
       | Error
           (Backend_openai_parse.Provider_error
             { message; error_type = _; provider_status = _; report = _ })
       | Error (Backend_openai_parse.Unreadable_response message) ->
         provider_parse_failure ~parser:"glm" message)
  with
  | Yojson.Json_error message
  | Yojson.Safe.Util.Type_error (message, _)
  | Yojson.Safe.Util.Undefined (message, _) ->
    provider_parse_failure
      ~parser:(Provider_config.string_of_provider_kind provider_kind)
      message
  | Backend_gemini.Gemini_api_error message ->
    Error
      (Http_client.HttpError
         { code = 400
         ; body = Http_client.Received ("Gemini API error: " ^ message)
         ; retry_after_header = None
         })
  | Backend_glm.Glm_api_error error ->
    (match error.origin with
     | Backend_glm.Response_parse -> provider_parse_failure ~parser:"glm" error.message
     | Backend_glm.Provider_response ->
       (match error.error_class with
        | Backend_glm.Glm_context_overflow ->
          (* agent-core boundary: keep the provider-reported overflow typed instead of
             flattening it into an HTTP 400 body string — consumers reach
             their compaction/shrink path only on a typed overflow. glm's
             envelope does not carry the token limit. *)
          Error
            (Http_client.ProviderFailure
               { kind = Http_client.Context_overflow { limit = None }
               ; message = error.message
               })
        | Backend_glm.Glm_quota_exceeded
        | Backend_glm.Glm_rate_limited
        | Backend_glm.Glm_auth_error
        | Backend_glm.Glm_server_error
        | Backend_glm.Glm_invalid_request ->
          let semantic_code =
            Backend_glm.http_code_of_glm_error_class error.error_class
          in
          let body =
            match error.code with
            | Some code -> Printf.sprintf "Glm error %s: %s" code error.message
            | None -> Printf.sprintf "Glm error without code: %s" error.message
          in
          Error
            (Http_client.HttpError
               { code = semantic_code
               ; body = Http_client.Received body
               ; retry_after_header = None
               })))
  | exn ->
    Reserved_exn.reraise_if_reserved exn;
    let message = Printexc.to_string exn in
    Error
      (Http_client.HttpError
         { code = 500
         ; body = Http_client.Received ("Unexpected parsing exception: " ^ message)
         ; retry_after_header = None
         })
;;

let%test "sync: an error finish without a provider condition is provider-reported" =
  let parse body =
    parse_sync_response
      ~http_codec:
        (Provider_http_codec.of_config
           (Provider_config.make ~kind:Provider_config.OpenAI_compat ~model_id:"m" ~base_url:"u" ()))
      ~provider_kind:Provider_config.OpenAI_compat
      body
  in
  (match
     parse
       {|{"id":"c","model":"m","choices":[{"index":0,"finish_reason":"error","message":{"content":"partial"},"error":{"message":"Provider disconnected","metadata":{"error_type":"provider_unavailable"}}}]}|}
   with
   | Error
       (Http_client.ProviderFailure
         { kind =
             Http_client.Provider_reported_error { error_type = Some "provider_unavailable" }
         ; message = "Provider disconnected"
         }) -> true
   | Ok _ | Error _ -> false)
  && (match
        parse
          {|{"id":"c","model":"m","choices":[{"index":0,"finish_reason":"error","message":{"content":"partial"},"error":{"code":400,"message":"bad"}}]}|}
      with
      | Error
          (Http_client.ProviderFailure
            { kind = Http_client.Provider_reported_error { error_type = None }
            ; message = "bad"
            }) -> true
      | Ok _ | Error _ -> false)
  &&
  match parse {|{"error":{"message":"Invalid API key","type":"invalid_request_error"}}|} with
  | Error
      (Http_client.ProviderFailure
        { kind =
            Http_client.Provider_reported_error { error_type = Some "invalid_request_error" }
        ; message = "Invalid API key"
        }) -> true
  | Ok _ | Error _ -> false
;;

let%test "sync: a top-level 502 is that refusal with the error object as its body" =
  match
    parse_sync_response
      ~http_codec:
        (Provider_http_codec.of_config
           (Provider_config.make ~kind:Provider_config.OpenAI_compat ~model_id:"m" ~base_url:"u" ()))
      ~provider_kind:Provider_config.OpenAI_compat
      {|{"id":"c","model":"m","error":{"code":502,"message":"Provider disconnected"},"choices":[{"index":0,"finish_reason":"error","message":{"content":"partial"}}]}|}
  with
  | Error
      (Http_client.HttpError
        { code = 502; body = Http_client.Received body; retry_after_header = None }) ->
    String.equal body {|{"error":{"code":502,"message":"Provider disconnected"}}|}
  | Ok _ | Error _ -> false
;;

let%test "sync: an unreadable response is a provider parse failure" =
  match
    parse_sync_response
      ~http_codec:
        (Provider_http_codec.of_config
           (Provider_config.make ~kind:Provider_config.OpenAI_compat ~model_id:"m" ~base_url:"u" ()))
      ~provider_kind:Provider_config.OpenAI_compat
      {|{"id":"c","model":"m","choices":[{"message":{"content":"ok"}}]}|}
  with
  | Error
      (Http_client.ProviderFailure
        { kind = Http_client.Provider_parse_error { parser = Some parser }
        ; message = "malformed_openai_response:missing_finish_reason"
        }) ->
    String.equal
      parser
      (Provider_config.string_of_provider_kind Provider_config.OpenAI_compat)
  | Ok _ | Error _ -> false
;;

type resolved_sync_transport =
  | Sync_response of Http_client.raw_sync_response
  | Sync_failure_before_response of Http_client.http_error
  | Sync_failure_after_response of
      { status : int
      ; error : Http_client.http_error
      }

let resolve_sync_transport = function
  | Ok (receipt : Http_client.sync_transport_receipt) -> Sync_response receipt.response
  | Error (Http_client.Before_dispatch_error error)
  | Error (Http_client.Dispatch_started_error error) ->
    Sync_failure_before_response error
  | Error (Http_client.Response_received_error { status; error }) ->
    Sync_failure_after_response { status; error }
;;

let%test "response-received transport failures retain their observed status" =
  let error =
    Http_client.ProviderFailure
      { kind = Http_client.Response_body_too_large { limit_bytes = 16 }
      ; message = "too large"
      }
  in
  match
    resolve_sync_transport
      (Error (Http_client.Response_received_error { status = 200; error }))
  with
  | Sync_failure_after_response
      { status = 200; error = Http_client.ProviderFailure _ } -> true
  | Sync_response _
  | Sync_failure_before_response _
  | Sync_failure_after_response _ -> false
;;

let complete_http
      ~sw:_
      ~net
      ?clock
      ?(on_http_status :
         (provider:string -> model_id:string -> status:int -> unit) option)
      ?body_timeout_s
      ?(connection_cache : Http_client.cache option)
      ?capture_id
      ?request_wire_observer
      ?admitted_body
      ~(config : Provider_config.t)
      ~(messages : Types.message list)
      ~tools
      ()
  =
  let validation =
    match admitted_body with
    | Some _ -> Ok ()
    | None -> validate_all config
  in
  let preflight =
    match validation with
    | Error err -> Error err
    | Ok () ->
      (match
         Http_client.resolve_explicit_deadline
           ~operation:"complete_http"
           ~parameter:"body_timeout_s"
           ~clock
           ~timeout_s:body_timeout_s
       with
       | Error _ as error -> error
       | Ok body_deadline ->
         Result.bind
           (match admitted_body with
            | None ->
              serialize_final_http_request_unadmitted
                ~stream:false
                ~config
                ~messages
                ~tools
            | Some admitted_body ->
              let evidence =
                Prepared_completion_request.admitted_body_evidence admitted_body
              in
              if evidence.stream
              then
                Error
                  (Http_client.AcceptRejected
                     { reason =
                         "streaming admitted body cannot be dispatched through the sync \
                          path"
                     })
              else
                Ok
                  ( Prepared_completion_request.admitted_body_http_codec admitted_body
                  , Prepared_completion_request.admitted_body_contents admitted_body ))
           (fun (http_codec, body_str) -> Ok (body_deadline, http_codec, body_str)))
  in
  match preflight with
  | Error err -> Error err, None
  | Ok (body_deadline, http_codec, body_str) ->
    if requires_non_http_transport config.kind
    then
      ( Error
          (Http_client.NetworkError
             { message =
                 Printf.sprintf
                   "%s provider requires a transport"
                   (Provider_config.string_of_provider_kind config.kind)
             ; kind = Unknown
             })
      , None )
    else (
      let provider_name = Provider_registry.provider_name_of_config config in
      let emit_status code =
        match on_http_status with
        | Some cb -> cb ~provider:provider_name ~model_id:config.model_id ~status:code
        | None -> ()
      in
      let url =
        match config.kind with
        | Provider_config.Gemini -> gemini_url ~config ~stream:false
        | Anthropic | Kimi | OpenAI_compat | Ollama | Glm ->
          config.base_url ^ config.request_path
      in
      (* Pre-flight body validation: detect truncated JSON before sending.
     Yojson.Safe.to_string should always produce balanced JSON, but if it
     doesn't, catching it here gives us the full body for diagnosis. *)
      let body_len = String.length body_str in
      let body_balanced =
        body_len >= 2 && body_str.[0] = '{' && body_str.[body_len - 1] = '}'
      in
      if (not body_balanced) && body_len > 0
      then (
        Diag.error
          "complete"
          "pre-flight: unbalanced JSON body (%d bytes, first=%C last=%C) for %s %s — \
           request blocked"
          body_len
          body_str.[0]
          body_str.[body_len - 1]
          provider_name
          config.model_id;
        (* Fail-closed: do not send a body the provider will reject.
       Previously this was WARN-and-continue, which let malformed
       payloads through to produce cryptic server-side errors
       (e.g. Ollama yyjson "can't find closing '}' symbol"). *)
        ( Error
            (Http_client.HttpError
               { code = 0
               ; body =
                   Http_client.Received
                     (Printf.sprintf
                        "pre-flight: unbalanced JSON body (%d bytes, first=%C last=%C)"
                        body_len
                        body_str.[0]
                        body_str.[body_len - 1])
               ; retry_after_header = None
               })
        , None ))
      else (
        let ( let* ) result f = match result with
          | Ok value -> f value
          | Error reason -> Error (Http_client.AcceptRejected { reason }), None
        in
        let* auth_headers = Provider_config.resolve_auth_headers config in
        let base_headers = config.headers @ auth_headers in
        let request_headers =
          ("content-length", string_of_int body_len)
          :: (match connection_cache with
              | Some _ -> base_headers
              | None -> ("connection", "close") :: base_headers)
        in
        match
          Http_client.prepare_sync_request
            ~url
            ~headers:request_headers
            ~body:body_str
        with
        | Error error -> Error error, None
        | Ok request ->
          let provider_label = provider_name in
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
               ~stream:false
               ~body:body_str
               ());
          Diag.debug
            "complete"
            "%s %s → %s (%d bytes)"
            provider_label
            config.model_id
            url
            body_len;
          let latency_counter = start_latency_counter ?clock () in
          (* The provider's connect budget bounds the wait for the response
             headers here as it does on the streaming path: connection,
             request and status line under one window. The sync path
             dispatched without it, and without the clock, so a server that
             accepted the request and never answered held a sync call for as
             long as the socket stayed open unless the caller declared a body
             deadline as well. *)
          let post_sync_call () =
            Http_client.dispatch_sync_request
              ?cache:connection_cache
              ?clock
              ?connect_timeout_s:config.connect_timeout_s
              ~net
              request
              ()
          in
          (* Body-level deadline (since 0.195.0): wraps the entire validated
             one-dispatch transport in [Eio.Time.with_timeout] so a slow
             non-streaming provider (no progress on the wire, or progress
             slower than caller can tolerate) cannot hang indefinitely.
             Streaming calls deliberately use [stream_idle_timeout_s] instead
             of a total body deadline.

             No silent failure: on expiry we return a structured
             [TimeoutError { phase = Non_streaming_body }] whose message
             identifies the body deadline, so retry layers treat it
             as retryable with operator-visible attribution. *)
          let post_response =
            match run_with_body_deadline body_deadline post_sync_call with
            | Body_deadline_exceeded timeout_s ->
              Error (non_streaming_body_timeout timeout_s)
            | Body_completed transport_result ->
              (match resolve_sync_transport transport_result with
               | Sync_response response ->
                 emit_status response.status;
                 Ok response
               | Sync_failure_before_response error -> Error error
               | Sync_failure_after_response { status; error } ->
                 emit_status status;
                 Error error)
          in
        let result =
          match post_response with
          | Error _ as e -> e
          | Ok response ->
            let code = response.status in
            let body = response.body in
            if code >= 200 && code < 300
            then (
              (* Same resolution as the streaming path: whether this model
                 embeds reasoning in its content channel is catalog data,
                 resolved through the provider-qualified lookup so a capability
                 declared only on a provider row is visible here too. *)
              let content_inline_reasoning =
                match Provider_config.capabilities_for_config_model config with
                | Some caps -> caps.Capabilities.content_inline_reasoning
                | None -> Capabilities.No_content_inline_reasoning
              in
              parse_sync_response
                ~content_inline_reasoning
                ~http_codec
                ~provider_kind:config.kind
                body)
            else (
              (* Log request body diagnostics on error responses to help debug
             Ollama "closing '}' symbol" and similar body-rejection errors. *)
              if code >= 400
              then (
                (* Strong validation: round-trip parse the body we sent.  The
               cheap balanced=true check only inspects first/last char and
               misses internal corruption.  When the body is well-formed
               JSON locally yet the server rejects it as "can't find closing
               '}' symbol", that points at server-side parser limits and we
               want the *exact* body for offline reproduction. *)
                let parse_ok =
                  try
                    let _ = Yojson.Safe.from_string body_str in
                    true
                  with
                  | _json_parse_error -> false
                in
                (* Mask api_key to a short fingerprint so log lines distinguish
               same-provider calls that use different keys (e.g.
               ZAI_API_KEY vs ZAI_CODING_API_KEY for glm vs glm-coding).
               Empty key renders as "-"; short keys render as "<len:N>"
               since they cannot be safely sampled. *)
                let api_key_tag =
                  let k = config.api_key in
                  if Secret.is_empty k
                  then "-"
                  else (
                    let len = Secret.length k in
                    if len < 8
                    then Printf.sprintf "len:%d" len
                    else Printf.sprintf "fp:%s(len:%d)" (Secret.fingerprint k) len)
                in
                Diag.warn
                  "complete"
                  "HTTP %d from %s (model=%s base_url=%s request_path=%s key=%s): \
                   req_body=%d bytes balanced=%b parse_ok=%b resp_body=%s"
                  code
                  provider_name
                  config.model_id
                  (sanitize_url_for_log config.base_url)
                  (sanitize_url_for_log config.request_path)
                  api_key_tag
                  body_len
                  body_balanced
                  parse_ok
                  (if String.length body <= 200
                   then body
                   else String.sub body 0 200 ^ "..."));
              let body =
                http_error_diagnostic_body ~provider_name ~config ~url ~code ~body
              in
              Error
                (Http_client.HttpError
                   { code
                   ; body = Http_client.Received body
                   ; retry_after_header = response.retry_after_header
                   }))
        in
        let latency_ms = latency_ms_int latency_counter in
        result, latency_ms))
;;

(* body_balanced else-branch *)

(* ── Sync completion ─────────────────────────────────── *)
