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
      [AcceptRejected] cascades when the [reason] string carries a
      per-provider failure marker:
      - "does not support" — MASC's worker-layer wrapping of OAS
        [InvalidConfig] errors for [runtime_mcp_auth] and [tool_support]
        (documented at [oas_worker_named.ml:661-678]).
      - "rejected the request" — kimi_cli exit 1. The auth/config error
        is Moonshot-specific; another provider can succeed.
      - "startup crash" — gemini_cli top-level await / yoga_wasm. The
        CLI source explicitly marks this "so the cascade can move on".
      All of these are per-provider, not cascade-wide; a fallback provider
      may succeed where the current one rejected. See masc-mcp #9932
      (kimi fallback), #9850 (codex_cli runtime_mcp_auth). *)
end

module Metrics : sig
  val make :
    ?on_cache_hit:(model_id:string -> unit) ->
    ?on_cache_miss:(model_id:string -> unit) ->
    ?on_request_start:(model_id:string -> unit) ->
    ?on_request_end:(model_id:string -> latency_ms:int -> unit) ->
    ?on_error:(model_id:string -> error:string -> unit) ->
    ?on_http_status:(provider:string -> model_id:string -> status:int -> unit) ->
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
