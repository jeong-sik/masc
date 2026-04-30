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
    | Provider_failure_capacity_exhausted
    | Provider_failure_hard_quota
    | Provider_failure_capability_mismatch
    | Provider_failure_cli_policy_invalid
    | Provider_failure_cli_startup_failed
    | Provider_failure_unknown
    | Provider_terminal
        (** OAS [ProviderTerminal] — provider has signalled a terminal
            condition (e.g. claude_cli [error_max_turns]). Treat as
            cascade-stopping; the next provider would face the same
            agent-level limit. Sub-kind ([Max_turns]/[Other]) is
            collapsed here because [should_cascade] only needs the
            terminality bit; consumers wanting the message extract it
            via the original [ProviderTerminal] match. *)

  (* Case-insensitive substring check, mirroring [cascade_health_filter]. *)
  let contains_ci ?(max_scan = 512) ~haystack ~needle () =
    let h =
      String.lowercase_ascii
        (if String.length haystack > max_scan then String.sub haystack 0 max_scan
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

  (* Ollama failing on large request bodies (~175KB+) returns 400 with
     "can't find closing '}'". See cascade_health_filter history. *)
  let is_provider_parse_error body =
    contains_ci ~haystack:body ~needle:"can't find closing" ()

  (* AcceptRejected is raised by OAS for multiple distinct conditions, all
     of which are per-provider rather than cascade-wide. A different provider
     in the cascade may handle the request even when the current one rejects:
     (a) Per-provider permanent failures from subprocess CLI transports.
         - kimi_cli exit 1: [transport_kimi_cli.ml] labels this
           "permanent auth/config/model error". The auth/config is specific
           to Moonshot; claude/gpt/ollama providers are unaffected.
         - gemini_cli startup crash: [transport_gemini_cli.ml] explicitly
           marks the AcceptRejected with "rejecting without retry so the
           cascade can move on".
     (b) Provider capability mismatches wrapped by MASC's worker layer at
         [oas_worker_named.ml:672-678] (InvalidConfig runtime_mcp_auth /
         tool_support). The detail string is built in
         [oas_worker_exec_transport.ml] and starts with "<provider> does not
         support ...". Another provider with matching capability can succeed.
     The markers below cover (a) and (b). CompletionContractViolation and
     UnrecognizedStopReason use free-form [reason] and are not whitelisted
     here — their cascade intent is tracked at their own call sites in
     [oas_worker_named.ml:673-678]. See masc-mcp #9932 (kimi fallback),
     #9850 (codex_cli runtime_mcp_auth). *)
  let accept_rejected_cascadable_markers = [
    "does not support";
    "rejected the request";  (* kimi_cli exit 1 — #9932 *)
    "startup crash";          (* gemini_cli top-level await / yoga_wasm *)
  ]

  let accept_rejected_is_cascadable reason =
    List.exists
      (fun needle -> contains_ci ~haystack:reason ~needle ())
      accept_rejected_cascadable_markers

  let classify_provider_failure
      (kind : Llm_provider.Http_client.provider_failure_kind) =
    match kind with
    | Capacity_exhausted _ -> Provider_failure_capacity_exhausted
    | Hard_quota _ -> Provider_failure_hard_quota
    | Capability_mismatch _ -> Provider_failure_capability_mismatch
    | Cli_policy_invalid _ -> Provider_failure_cli_policy_invalid
    | Cli_startup_failed _ -> Provider_failure_cli_startup_failed
    | Provider_parse_error _ -> Provider_parse_error
    | Unknown_provider_failure _ -> Provider_failure_unknown

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
        when List.mem code [ 400; 422 ] && is_provider_parse_error body ->
          Provider_parse_error
      | Llm_provider.Http_client.HttpError { code; _ } ->
          if List.mem code Llm_provider.Constants.Http.cascadable_codes then
            Transient_http code
          else
            Terminal_http code
      | Llm_provider.Http_client.AcceptRejected { reason } ->
          if accept_rejected_is_cascadable reason then
            Accept_rejected_capability_mismatch
          else
            Accept_rejected_terminal
      | Llm_provider.Http_client.CliTransportRequired _ ->
          Cli_transport_required
      | Llm_provider.Http_client.ProviderTerminal _ ->
          Provider_terminal
      | Llm_provider.Http_client.ProviderFailure { kind; _ } ->
          classify_provider_failure kind
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
    | Provider_failure_capacity_exhausted
    | Provider_failure_hard_quota
    | Provider_failure_capability_mismatch
    | Provider_failure_cli_policy_invalid
    | Provider_failure_cli_startup_failed
    | Provider_failure_unknown
    | Network_error ->
        true

  let error_message (err : Llm_provider.Http_client.http_error) : string =
    match err with
    | Llm_provider.Http_client.NetworkError { message; _ } -> message
    | Llm_provider.Http_client.ProviderFailure { kind; message } ->
        Llm_provider.Http_client.provider_failure_to_string ~kind ~message
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
    | Llm_provider.Http_client.HttpError { code; body } -> (
        try
          let json = Yojson.Safe.from_string body in
          match Yojson.Safe.Util.member "error" json with
          | `Assoc fields -> (
              match List.assoc_opt "message" fields with
              | Some (`String msg) -> msg
              | _ -> Printf.sprintf "HTTP %d" code)
          | _ -> Printf.sprintf "HTTP %d" code
        with Yojson.Json_error _ -> Printf.sprintf "HTTP %d" code)
end

module Metrics = struct
  let default_model_hook ~model_id:_ = ()
  let default_request_end ~model_id:_ ~latency_ms:_ = ()
  let default_error ~model_id:_ ~error:_ = ()
  let default_http_status ~provider:_ ~model_id:_ ~status:_ = ()

  let make ?(on_cache_hit = default_model_hook)
      ?(on_cache_miss = default_model_hook)
      ?(on_request_start = default_model_hook)
      ?(on_request_end = default_request_end) ?(on_error = default_error)
      ?(on_http_status = default_http_status) () : Llm_provider.Metrics.t =
    {
      on_cache_hit;
      on_cache_miss;
      on_request_start;
      on_request_end;
      on_error;
      on_http_status;
    }
end
