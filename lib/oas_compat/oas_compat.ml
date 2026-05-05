(* See oas_compat.mli for module rationale. *)

module Http_client = struct
  type cascade_failure_class =
    | Local_resource_exhaustion
    | Context_overflow
    | Provider_parse_error
    | Transient_http of int
    | Terminal_http of int
    | Accept_rejected_capability_mismatch
    | Accept_rejected_terminal
    | Cli_transport_required
    | Network_error
    | Provider_terminal
        (** OAS [ProviderTerminal] — provider has signalled a terminal
            condition (e.g. claude_cli [error_max_turns]). Treat as
            cascade-stopping; the next provider would face the same
            agent-level limit. Sub-kind ([Max_turns]/[Other]) is
            collapsed here because [should_cascade] only needs the
            terminality bit; consumers wanting the message extract it
            via the original [ProviderTerminal] match. *)
    | Provider_capacity_exhausted
    | Provider_hard_quota
    | Provider_capability_mismatch
    | Provider_cli_policy_invalid
    | Provider_cli_startup_failed
    | Provider_failure_parse_error
    | Provider_failure_unknown

  (** Structured error codes for conditions that previously required
      case-insensitive substring scanning of raw provider message strings.

      Each variant corresponds to a concrete per-provider failure mode
      that was originally identified via string markers (M04/M05).
      Keeping the conversion quarantined in [classify_accept_rejected] and
      [is_http_body_parse_error] means:
        1. String fragility is isolated — message-format changes only
           break one small function each.
        2. Downstream cascade logic branches on variant, not string.
        3. Adding a new signal requires only a new variant + one clause,
           not a new magic-needle in a shared list. *)
  type retryable_error =
    | Parse_error
        (** HTTP body signals a provider-side JSON parse failure.
            Originally detected via [contains_ci "can't find closing"]
            (M04). Ollama returning 400 on large request bodies
            (~175 KB+) is the canonical trigger.  The cascade should
            advance because the body size limit is local to this
            provider. *)
    | Model_unsupported
        (** Provider explicitly reports that the requested model or
            capability is not supported.
            Originally detected via [contains_ci "does not support"]
            (M05).  Covers codex_cli [runtime_mcp_auth] /
            [tool_support] InvalidConfig wrappers built in
            [oas_worker_exec_transport.ml].  Another provider in the
            cascade may support the capability. *)
    | Request_rejected
        (** Provider subprocess exited with a permanent rejection.
            Originally detected via [contains_ci "rejected the request"]
            (M05).  Canonical case: kimi_cli exit 1 — the auth/config
            error is Moonshot-specific; other providers are unaffected.
            See masc-mcp #9932. *)
    | Startup_crash
        (** Provider CLI crashed before processing the request.
            Originally detected via [contains_ci "startup crash"] (M05).
            Covers gemini_cli top-level-await / yoga_wasm and kimi_cli
            process-title UnicodeDecodeError.  The CLI source marks
            these "so the cascade can move on". *)

  let classify_provider_failure_kind =
    let module H = Llm_provider.Http_client in
    function
    | H.Capacity_exhausted _ -> Provider_capacity_exhausted
    | H.Hard_quota _ -> Provider_hard_quota
    | H.Capability_mismatch _ -> Provider_capability_mismatch
    | H.Cli_policy_invalid _ -> Provider_cli_policy_invalid
    | H.Cli_startup_failed _ -> Provider_cli_startup_failed
    | H.Provider_parse_error _ -> Provider_failure_parse_error
    | H.Unknown_provider_failure _ -> Provider_failure_unknown

  (* String-matching quarantine zone.
     All case-insensitive substring checks live here and nowhere else.
     When OAS or a provider changes a message format, only this section
     needs updating.  Downstream cascade code uses [retryable_error]
     variants, not raw strings. *)

  let max_scan_bytes = 512

  (* Case-insensitive substring check — O(n*m) but the haystack scan is
     capped at [max_scan_bytes] so the worst-case cost is fixed. *)
  let contains_ci_scan_limited ~haystack ~needle =
    let h =
      String.lowercase_ascii
        (if String.length haystack > max_scan_bytes then
           String.sub haystack 0 max_scan_bytes
         else haystack)
    in
    let n = String.lowercase_ascii needle in
    let nlen = String.length n in
    let hlen = String.length h in
    if nlen = 0 || nlen > hlen then false
    else
      let rec scan i =
        if i > hlen - nlen then false
        else if String.sub h i nlen = n then true
        else scan (i + 1)
      in
      scan 0

  (** Classify an [AcceptRejected] reason string into a structured
      [retryable_error] code.

      Returns [Some code] when the reason matches a known per-provider
      failure marker; [None] for reasons with no recognised marker
      (e.g. [output_schema] violations), which remain terminal
      ([Accept_rejected_terminal]). *)
  let classify_accept_rejected reason : retryable_error option =
    (* Model/capability unsupported — MASC worker-layer wrapping of OAS
       InvalidConfig errors (#9850). *)
    if contains_ci_scan_limited ~haystack:reason ~needle:"does not support" then
      Some Model_unsupported
    (* kimi_cli permanent auth/config/model rejection (#9932). *)
    else if contains_ci_scan_limited ~haystack:reason ~needle:"rejected the request" then
      Some Request_rejected
    (* gemini_cli / kimi_cli CLI startup failures. *)
    else if contains_ci_scan_limited ~haystack:reason ~needle:"startup crash" then
      Some Startup_crash
    else
      None

  (** Return [true] when an HTTP 400/422 body signals a provider-side
      JSON parse failure (M04).
      Ollama fails with "can't find closing '}'" on large bodies (~175 KB+). *)
  let is_http_body_parse_error body =
    contains_ci_scan_limited ~haystack:body ~needle:"can't find closing"

  let classify (err : Llm_provider.Http_client.http_error) :
      cascade_failure_class =
    if Llm_provider.Http_client.is_local_resource_exhaustion err then
      Local_resource_exhaustion
    else
      match err with
      | Llm_provider.Http_client.HttpError { code; body }
        when List.mem code [ 400; 422 ]
             && Llm_provider.Retry.is_context_overflow_message body ->
          Context_overflow
      | Llm_provider.Http_client.HttpError { code; body }
        when List.mem code [ 400; 422 ] && is_http_body_parse_error body ->
          Provider_parse_error
      | Llm_provider.Http_client.HttpError { code; _ } ->
          if List.mem code Llm_provider.Constants.Http.cascadable_codes then
            Transient_http code
          else
            Terminal_http code
      | Llm_provider.Http_client.AcceptRejected { reason } -> (
          (* All [retryable_error] codes are per-provider — a different cascade
             hop may succeed.  The type name encodes this intent: any variant
             returned by [classify_accept_rejected] should advance the cascade.
             If a future code should NOT cascade, it belongs in a different
             type (or the call-site match should be extended at that point). *)
          match classify_accept_rejected reason with
          | Some _ -> Accept_rejected_capability_mismatch
          | None -> Accept_rejected_terminal)
      | Llm_provider.Http_client.CliTransportRequired _ ->
          Cli_transport_required
      | Llm_provider.Http_client.ProviderTerminal _ ->
          Provider_terminal
      | Llm_provider.Http_client.ProviderFailure { kind; _ } ->
          classify_provider_failure_kind kind
      | Llm_provider.Http_client.NetworkError _ -> Network_error

  let should_cascade (err : Llm_provider.Http_client.http_error) : bool =
    match classify err with
    | Local_resource_exhaustion
    | Terminal_http _
    | Accept_rejected_terminal
    | Provider_terminal ->
        false
    | Context_overflow
    | Provider_parse_error
    | Transient_http _
    | Accept_rejected_capability_mismatch
    | Cli_transport_required
    | Network_error
    | Provider_capacity_exhausted
    | Provider_hard_quota
    | Provider_capability_mismatch
    | Provider_cli_policy_invalid
    | Provider_cli_startup_failed
    | Provider_failure_parse_error
    | Provider_failure_unknown ->
        true

  let error_message (err : Llm_provider.Http_client.http_error) : string =
    match err with
    | Llm_provider.Http_client.NetworkError { message; _ } -> message
    | Llm_provider.Http_client.AcceptRejected { reason } -> reason
    | Llm_provider.Http_client.CliTransportRequired { kind } ->
        Printf.sprintf "%s provider requires a CLI transport" kind
    | Llm_provider.Http_client.ProviderTerminal
        { kind = Llm_provider.Http_client.Max_turns { turns; limit }; message } ->
        Printf.sprintf "provider terminal: max turns exceeded (%d/%d): %s"
          turns limit message
    | Llm_provider.Http_client.ProviderTerminal
        { kind = Llm_provider.Http_client.Other subtype; message } ->
        Printf.sprintf "provider terminal: %s: %s" subtype message
    | Llm_provider.Http_client.ProviderFailure { kind; message } ->
        Llm_provider.Http_client.provider_failure_to_string ~kind ~message
    | Llm_provider.Http_client.HttpError { code; body } -> (
        let truncate_body b =
          let max_len =
            Llm_provider.Constants.Truncation.max_error_body_length
          in
          if String.length b <= max_len then b
          else String.sub b 0 max_len ^ "…"
        in
        try
          let json = Yojson.Safe.from_string body in
          match Yojson.Safe.Util.member "error" json with
          | `Assoc fields -> (
              match List.assoc_opt "message" fields with
              | Some (`String msg) -> msg
              | _ ->
                Printf.sprintf "HTTP %d (body: %s)" code (truncate_body body))
          | _ ->
            Printf.sprintf "HTTP %d (body: %s)" code (truncate_body body)
        with Yojson.Json_error _ ->
          Printf.sprintf "HTTP %d (body: %s)" code (truncate_body body))
end

module Metrics = struct
  let default_model_hook ~model_id:_ = ()
  let default_request_end ~model_id:_ ~latency_ms:_ = ()
  let default_error ~model_id:_ ~error:_ = ()
  let default_http_status ~provider:_ ~model_id:_ ~status:_ = ()
  let default_capability_drop ~model_id:_ ~field:_ = ()
  (* agent_sdk 0.185.0 added [on_retry] and [on_token_usage] to
     Llm_provider.Metrics.t.  PR #13062 bumped the pin to 0.190.1
     in main, so the record now has 9 fields and these two must be
     supplied.  Default to no-op so existing callers that only
     supply legacy hooks keep compiling unchanged. *)
  let default_retry ~provider:_ ~model_id:_ ~attempt:_ = ()
  let default_token_usage ~provider:_ ~model_id:_ ~input_tokens:_
      ~output_tokens:_ = ()

  let make ?(on_cache_hit = default_model_hook)
      ?(on_cache_miss = default_model_hook)
      ?(on_request_start = default_model_hook)
      ?(on_request_end = default_request_end) ?(on_error = default_error)
      ?(on_http_status = default_http_status)
      ?(on_capability_drop = default_capability_drop)
      ?(on_retry = default_retry)
      ?(on_token_usage = default_token_usage) ()
      : Llm_provider.Metrics.t =
    {
      on_cache_hit;
      on_cache_miss;
      on_request_start;
      on_request_end;
      on_error;
      on_http_status;
      on_capability_drop;
      on_retry;
      on_token_usage;
    }
end
