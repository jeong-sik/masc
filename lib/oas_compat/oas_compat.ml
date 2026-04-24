(* See oas_compat.mli for module rationale. *)

module Http_client = struct
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

  (* AcceptRejected is raised by OAS for multiple distinct conditions:
     (a) permanent provider failures (kimi_cli exit 1 is explicitly labeled
         "permanent auth/config/model error") — must NOT cascade.
     (b) provider capability mismatches wrapped by MASC's worker layer at
         [oas_worker_named.ml:672-678] (InvalidConfig runtime_mcp_auth /
         tool_support). The worker comment at line 661-665 documents explicit
         cascade intent. The detail string is built in
         [oas_worker_exec_transport.ml:444-452] and consistently starts with
         "<provider> does not support ...".
     This filter whitelists only markers from class (b). Class (a) has no
     matching marker and falls through to false. CompletionContractViolation
     and UnrecognizedStopReason use free-form [reason] and are not whitelisted
     here — their cascade intent is tracked separately. See masc-mcp #9850. *)
  let accept_rejected_cascadable_markers = [
    "does not support";
  ]

  let accept_rejected_is_cascadable reason =
    List.exists
      (fun needle -> contains_ci ~haystack:reason ~needle ())
      accept_rejected_cascadable_markers

  let should_cascade (err : Llm_provider.Http_client.http_error) : bool =
    if Llm_provider.Http_client.is_local_resource_exhaustion err then false
    else
      match err with
      | Llm_provider.Http_client.HttpError { code; body }
        when List.mem code [ 400; 422 ]
             && (Llm_provider.Retry.is_context_overflow_message body
                || is_provider_parse_error body) ->
          true
      | Llm_provider.Http_client.HttpError { code; _ } ->
          List.mem code Llm_provider.Constants.Http.cascadable_codes
      | Llm_provider.Http_client.AcceptRejected { reason } ->
          accept_rejected_is_cascadable reason
      | Llm_provider.Http_client.CliTransportRequired _ -> true
      | Llm_provider.Http_client.NetworkError _ -> true
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
