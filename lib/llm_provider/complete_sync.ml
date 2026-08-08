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

let with_body_deadline body_deadline f =
  match body_deadline with
  | Http_client.Unbounded -> f ()
  | Http_client.Bounded (clock, timeout_s) ->
    (match Eio.Time.with_timeout clock timeout_s (fun () -> Ok (f ())) with
     | Ok result -> result
     | Error `Timeout -> Error (non_streaming_body_timeout timeout_s))
;;

let%test "with_body_deadline does not relabel a nested timeout exception" =
  Eio_main.run
  @@ fun env ->
  let deadline = Http_client.Bounded (Eio.Stdenv.clock env, 1.0) in
  match with_body_deadline deadline (fun () -> raise Eio.Time.Timeout) with
  | exception Eio.Time.Timeout -> true
  | (exception _) | Ok _ | Error _ -> false
;;

let provider_parse_failure ?parser message =
  Error
    (Http_client.ProviderFailure
       { kind = Http_client.Provider_parse_error { parser }; message })
;;

(** Parse one successful HTTP response using only the frozen wire codec and
    provider kind. This function performs no request serialization, provider
    lookup, pricing lookup, dispatch, or retry. *)
let parse_sync_response ~http_codec ~provider_kind body =
  try
    match http_codec with
    | Provider_http_codec.Anthropic_messages ->
      Ok (Backend_anthropic.parse_response (Yojson.Safe.from_string body))
    | Provider_http_codec.Ollama_chat ->
      (match Backend_ollama.parse_ollama_response body with
       | Ok response -> Ok response
       | Error message ->
         Error
           (Http_client.HttpError
              { code = 400; body = message; retry_after_header = None }))
    | Provider_http_codec.Openai_responses ->
      (match Backend_openai_responses.parse_response_result body with
       | Ok response -> Ok response
       | Error message ->
         Error
           (Http_client.HttpError
              { code = 400; body = message; retry_after_header = None }))
    | Provider_http_codec.Openai_chat ->
      (match Backend_openai_parse.parse_openai_response_result body with
       | Ok response -> Ok response
       | Error (Backend_openai_parse.Provider_error message) ->
         Error
           (Http_client.HttpError
              { code = 400; body = message; retry_after_header = None })
       | Error (Backend_openai_parse.Empty_completion empty) ->
         Error (Http_client.empty_completion_error ~stop_reason:empty.stop_reason))
    | Provider_http_codec.Gemini_generate_content ->
      Ok (Backend_gemini.parse_response (Yojson.Safe.from_string body))
    | Provider_http_codec.Glm_chat ->
      (match Backend_glm.parse_response_result body with
       | Ok response -> Ok response
       | Error (Backend_openai_parse.Empty_completion empty) ->
         Error (Http_client.empty_completion_error ~stop_reason:empty.stop_reason)
       | Error (Backend_openai_parse.Provider_error message) ->
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
         { code = 400; body = "Gemini API error: " ^ message; retry_after_header = None })
  | Backend_glm.Glm_api_error error ->
    (match error.origin with
     | Backend_glm.Response_parse -> provider_parse_failure ~parser:"glm" error.message
     | Backend_glm.Provider_response ->
       (match error.error_class with
        | Backend_glm.Glm_context_overflow ->
          (* oas#2947: keep the provider-reported overflow typed instead of
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
               { code = semantic_code; body; retry_after_header = None })))
  | exn ->
    Reserved_exn.reraise_if_reserved exn;
    let message = Printexc.to_string exn in
    Error
      (Http_client.HttpError
         { code = 500
         ; body = "Unexpected parsing exception: " ^ message
         ; retry_after_header = None
         })
;;

let complete_http
      ~sw
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
           (fun (http_codec, body_str) ->
              match admitted_body with
              | Some _ -> Ok (body_deadline, http_codec, body_str)
              | None ->
                Result.map
                  (fun body_str -> body_deadline, http_codec, body_str)
                  (admit_final_serialized_body ~config body_str)))
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
        | Anthropic | Kimi | OpenAI_compat | Ollama | Glm | DashScope ->
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
                   Printf.sprintf
                     "pre-flight: unbalanced JSON body (%d bytes, first=%C last=%C)"
                     body_len
                     body_str.[0]
                     body_str.[body_len - 1]
               ; retry_after_header = None
               })
        , None ))
      else (
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
        let post_sync_call () =
          Http_client.post_sync
            ?cache:connection_cache
            ~sw
            ~net
            ?clock
            ~url
            ~headers:(config.headers @ Provider_config.auth_headers_for_config config)
            ~body:body_str
            ()
        in
        (* Body-level deadline (since 0.195.0): wraps the entire
           [Http_client.post_sync] in [Eio.Time.with_timeout] so a slow
           non-streaming provider (no progress on the wire, or progress
           slower than caller can tolerate) cannot hang indefinitely.
           Streaming calls deliberately use [stream_idle_timeout_s] instead
           of a total body deadline.

           No silent failure: on expiry we return a structured
             [TimeoutError { phase = Non_streaming_body }] whose message
             identifies the body deadline, so retry layers treat it
             as retryable with operator-visible attribution. *)
        let post_response = with_body_deadline body_deadline post_sync_call in
        let result =
          match post_response with
          | Error _ as e -> e
          | Ok (code, body) ->
            (* Emit status counter as soon as we have a raw HTTP code from
           the provider, before any body-parse or retry decision. This
           gives downstream metrics an accurate count of provider
           responses (success and failure) without inflating from
           internal retries or body-parse fallbacks. *)
            emit_status code;
            if code >= 200 && code < 300
            then parse_sync_response ~http_codec ~provider_kind:config.kind body
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
               ZAI_API_KEY vs ZAI_API_KEY_SB for glm vs glm-coding).
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
              Error (Http_client.HttpError { code; body; retry_after_header = None }))
        in
        let latency_ms = latency_ms_int latency_counter in
        result, latency_ms))
;;

(* body_balanced else-branch *)

(* ── Sync completion ─────────────────────────────────── *)
