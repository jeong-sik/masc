(** MASC-side boundary adapter for OAS types.

    Consolidates pattern matches against OAS public variants (and
    record literals against OAS record types) to a single entry
    point. When OAS adds/renames/removes a variant or field, only
    this module fails to compile — downstream consumers route
    through the adapter and are isolated from boundary churn.

    Design references:
    - Claude Code's [src/bridge/types.ts] "narrow union for
      exhaustiveness; wire accepts any string" pattern
    - [scripts/oas-drift-check.sh] fingerprint gate (#8023) which
      detects drift at pin-bump time before reaching this adapter

    Scope: this initial adapter covers [Http_client.http_error] and
    [Metrics.t], the two surfaces whose MASC consumer is a record
    literal or small match. [Event_bus.payload] has an elaborate
    per-variant JSON projection in [oas_event_bridge.ml]; a full
    classifier is deferred to follow-up because a genuine abstraction
    there requires touching the JSON-emission path, which carries
    regression risk that should not ride this foundational PR. *)

module Http_client : sig
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
        (** Provider-level terminal condition that should stop cascading. *)
    | Provider_capacity_exhausted
    | Provider_hard_quota
    | Provider_capability_mismatch
    | Provider_cli_policy_invalid
    | Provider_cli_startup_failed
    | Provider_failure_parse_error
    | Provider_failure_unknown

  (** Structured error codes for conditions previously detected via
      case-insensitive substring scanning of raw provider message strings
      (anti-patterns M04/M05).

      The string-matching logic is quarantined inside
      [classify_accept_rejected] and [is_http_body_parse_error]; all
      downstream code should branch on this enum. *)
  type retryable_error =
    | Parse_error
        (** HTTP body signals a provider-side JSON parse failure (M04).
            Ollama returning 400 on large bodies (~175 KB+) is the
            canonical trigger; the cascade advances because the body-size
            limit is local to this provider. *)
    | Model_unsupported
        (** Provider explicitly reports that the requested model or
            capability is not supported (M05).  Covers codex_cli
            [runtime_mcp_auth] / [tool_support] InvalidConfig wrappers.
            Another provider in the cascade may support the capability. *)
    | Request_rejected
        (** Provider subprocess exited with a permanent rejection (M05).
            Canonical case: kimi_cli exit 1.  The auth/config error is
            Moonshot-specific; other providers are unaffected (#9932). *)
    | Startup_crash
        (** Provider CLI crashed before processing the request (M05).
            Covers gemini_cli top-level-await / yoga_wasm and kimi_cli
            process-title UnicodeDecodeError.  The CLI source marks these
            "so the cascade can move on". *)

  val classify_accept_rejected : string -> retryable_error option
  (** Classify an [AcceptRejected] reason string into a structured
      [retryable_error] code.

      Returns [Some code] when the reason matches a known per-provider
      failure marker ([Model_unsupported], [Request_rejected],
      [Startup_crash]); [None] for unrecognised reasons
      (e.g. output-schema violations), which are treated as
      [Accept_rejected_terminal].

      String matching is quarantined here; update only this function
      when provider message formats change. *)

  val is_http_body_parse_error : string -> bool
  (** Return [true] when an HTTP 400/422 body signals a provider-side
      JSON parse failure ([Parse_error] / M04).
      Ollama fails with ["can't find closing '}'"] on large bodies. *)

  val classify : Llm_provider.Http_client.http_error -> cascade_failure_class
  (** Classify an OAS HTTP/client failure into MASC's typed cascade boundary.

      Compatibility string checks remain quarantined in this adapter. Downstream
      cascade/FSM code should branch on this class rather than reparsing
      provider error text. *)

  val should_cascade : Llm_provider.Http_client.http_error -> bool
  (** Decide whether an error should cascade to the next provider.

      Exhaustive match over [Llm_provider.Http_client.http_error].
      Local resource exhaustion stops the cascade because every
      subsequent provider will hit the same bottleneck. HTTP errors
      cascade when the code is in
      [Llm_provider.Constants.Http.cascadable_codes] or when the body
      signals context overflow / provider parse error.
      [CliTransportRequired] cascades — the CLI provider cannot serve
      this request over HTTP, so the next provider must.
      [AcceptRejected] cascades when [classify_accept_rejected] returns
      a [retryable_error] code:
      - [Model_unsupported] — MASC's worker-layer wrapping of OAS
        [InvalidConfig] errors for [runtime_mcp_auth] and [tool_support]
        (documented at [oas_worker_named.ml:661-678]).
      - [Request_rejected] — kimi_cli exit 1. The auth/config error is
        Moonshot-specific; another provider can succeed.
      - [Startup_crash] — gemini_cli top-level await / yoga_wasm or
        kimi_cli process-title UnicodeDecodeError. The CLI source
        explicitly marks this "so the cascade can move on".
      All of these are per-provider, not cascade-wide; a fallback provider
      may succeed where the current one rejected. See masc-mcp #9932
      (kimi fallback), #9850 (codex_cli runtime_mcp_auth).

      [ProviderFailure] is already typed by OAS, so this adapter maps it
      without marker matching. Capacity, quota, capability, CLI policy/startup,
      provider parse, and unknown provider failures all advance the cascade as
      provider-local skip conditions. *)

  val error_message : Llm_provider.Http_client.http_error -> string
  (** Extract a human-readable message from an OAS HTTP error.

      Centralises the "render error for log/observation" logic so callers
      stop pattern-matching the OAS variant directly. When OAS adds a new
      [http_error] variant, only this adapter (and its [classify] /
      [should_cascade]) need to be updated — without this helper, every
      consumer carries its own copy of the match and a new variant breaks
      [warn-error +8] across the codebase (see #oas-providerterminal-sweep
      2026-04-26 cascade where 5 sites repeated the same match).

      For [HttpError] the body is parsed as JSON to surface the
      provider-supplied [error.message] when present; otherwise the HTTP
      status code is rendered. *)
end

module Metrics : sig
  val make :
    ?on_cache_hit:(model_id:string -> unit) ->
    ?on_cache_miss:(model_id:string -> unit) ->
    ?on_request_start:(model_id:string -> unit) ->
    ?on_request_end:(model_id:string -> latency_ms:int -> unit) ->
    ?on_error:(model_id:string -> error:string -> unit) ->
    ?on_http_status:(provider:string -> model_id:string -> status:int -> unit) ->
    ?on_capability_drop:(model_id:string -> field:string -> unit) ->
    unit ->
    Llm_provider.Metrics.t
  (** Construct a [Llm_provider.Metrics.t] value.

      Each callback is optional; unset callbacks and any OAS fields
      MASC does not consume receive no-op defaults. Adding a new
      field upstream forces an update in exactly one place — this
      module — rather than at every record-literal site.

      Rationale: record literals against a foreign record type are
      fragile under upstream churn because OCaml records require all
      fields to be set explicitly. Centralizing the literal here
      means field additions change this file and no other. *)
end
