(** SSOT for LLM-provider runtime error classification surfaced to
    keeper auto-resume reactors (Provider_capacity backpressure,
    Tier_admission watchdog, Provider_dns_failure, Provider_timeout).

    RFC-0142 §Phase 2 — PR-A.

    This module is the *boundary* typed variant.  PR-B onward wires it
    into [Keeper_registry_types.Provider_runtime_error.classified_as],
    and PR-C replaces the substring-and-magic-HTTP dispatch inside
    [Keeper_health_probe.provider_runtime_pressure_class] with a pure
    [match] on this type.

    PR-A scope (this PR): the type, named HTTP status constants, and
    wire tags.  Zero callers, zero behavioural change.  A
    [classify_raw] helper is deliberately *not* exposed — adapter-side
    typed emission (per-provider [Provider_a], [Openai_compat],
    [Llamacpp_local], …) belongs in PR-B-family so the substring soup
    moves to its single legitimate residence (the wire boundary), not
    a relocated copy inside the keeper layer.

    Adding a new named variant requires (a) at least one provider
    adapter that produces it and (b) a downstream keeper reactor that
    consumes it — otherwise the original payload is preserved verbatim
    in [Unspecified], which is a parse-don't-validate escape hatch,
    not a catch-all. *)

type response_timeout_kind =
  | Connection_timeout
      (** Underlying TCP/TLS handshake never completed.  Default kind
          for HTTP 408 / 504 / 524 status when no streaming-stage
          evidence is available. *)
  | First_token_timeout
      (** Streaming connection opened but no first token arrived
          before the agreed deadline.  Distinct from
          [Inter_chunk_idle] because retry strategy differs. *)
  | Inter_chunk_idle
      (** Streaming response stalled mid-flight between tokens. *)
  | Wall_clock_timeout
      (** Whole-turn wall-clock budget exceeded
          ([max_execution_time], orchestrator-side deadline). *)

type t =
  | Client_capacity_exhausted
      (** Local in-flight admission cap reached; the failure is on
          our side, not the provider.  RFC-0042 / RFC-0058 territory.
          Reactor: pause new admission, drain in-flight. *)
  | Tier_admission_exhausted of { capability_profile : string option }
      (** Cascade tier-group admission denied because every model in
          the strict capability profile is saturated or unavailable.
          [capability_profile] is the canonical profile name (e.g.
          [Some "strict_tool_candidates"]) when the adapter can
          attribute the denial to a specific profile, [None]
          otherwise. *)
  | Backpressure of
      { http_status : int
      ; retry_after_ms : int option
      }
      (** Provider explicitly signalled "slow down" — HTTP
          [too_many_requests] / [anthropic_overloaded], or vendor
          equivalents detected by the adapter.  [retry_after_ms]
          mirrors any [Retry-After] header.  Reactor: exponential
          backoff with jitter. *)
  | Dns_resolution_failure of { host : string option }
      (** Hostname could not be resolved.  [host] is the canonical
          host whose lookup failed when the adapter can name it.
          Reactor: pause cascade, mark route unhealthy. *)
  | Response_timeout of
      { kind : response_timeout_kind
      ; elapsed_ms : int option
      }
      (** Request timed out.  [kind] discriminates connection vs
          streaming-stage timeouts; [elapsed_ms] is the observed
          duration when the adapter measured it. *)
  | Unspecified of
      { raw_code : string
      ; raw_detail : string
      }
      (** Adapter could not classify the failure into one of the
          named variants.  [raw_code] / [raw_detail] preserve the
          original payload verbatim so dashboards and post-mortems
          retain the message.  Not a catch-all — never use this
          variant when a typed signal exists. *)

(** {1 Named HTTP status constants}

    These are the magic literals previously inlined in
    [Keeper_health_probe.provider_runtime_pressure_class].  Holding
    them in one named module lets adapters reference the same numbers
    by name, and lets PR-C delete the inline integer literals from the
    consumer. *)

module Http_status : sig
  val too_many_requests : int
  (** [429] — RFC 6585. *)

  val anthropic_overloaded : int
  (** [529] — Provider_a non-standard overload signal. *)

  val request_timeout : int
  (** [408] — HTTP/1.1. *)

  val gateway_timeout : int
  (** [504] — HTTP/1.1. *)

  val cloudflare_origin_timeout : int
  (** [524] — Cloudflare non-standard origin timeout. *)
end

val backpressure_http_statuses : int list
(** Canonical set used by adapters to map raw HTTP statuses to
    [Backpressure].  Stable list — adding to it requires a paired
    docstring entry on the named constant.  Reads:
    [[Http_status.too_many_requests; Http_status.anthropic_overloaded]]. *)

val timeout_http_statuses : int list
(** Canonical set used by adapters to map raw HTTP statuses to
    [Response_timeout { kind = Connection_timeout; _ }].  Reads:
    [[Http_status.request_timeout; Http_status.gateway_timeout;
      Http_status.cloudflare_origin_timeout]]. *)

(** {1 Wire tags}

    Stable string identifiers for telemetry, dashboards, and
    [Keeper_health_probe.runtime_pressure_class_of_label] migration. *)

val to_short_tag : t -> string
(** Returns the stable short tag.  One of:
    [client_capacity_exhausted], [tier_admission_exhausted],
    [backpressure], [dns_resolution_failure], [response_timeout],
    [unspecified]. *)

val response_timeout_kind_to_string : response_timeout_kind -> string
(** [connection_timeout] / [first_token_timeout] / [inter_chunk_idle] /
    [wall_clock_timeout]. *)

val raw_payload : t -> (string * string) option
(** [Some (raw_code, raw_detail)] for [Unspecified], [None]
    otherwise.  Provided so consumers that must surface a free-form
    error message (operator UI, post-mortem export) need not
    re-classify or destructure. *)
