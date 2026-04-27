(** Auth strictness flag (Phase A F2).

    Controls how [mcp_server_eio_execute] handles a bearer token that resolves
    to no credential.  The pre-Phase-A behavior was to silently keep the
    caller-supplied alias and emit a [silent:auth_token_resolve_error] warn —
    936 events/day in production (2026-04-26 measurement).

    Phase A F2 does not change behavior; it only adds a [would_reject]
    counter so operators can measure how many of those silent fallbacks
    represent legitimate vs illegitimate callers before Phase B PR-2 promotes
    [Strict] to a typed reject.

    Env flag values (canonical, case-insensitive):
    - [off]            : keep silent fallback, no [would_reject] emit
    - [dry_run]        : keep silent fallback, emit [would_reject] for soak
    - [strict]         : (Phase B PR-2) actually reject the request

    Default: [Dry_run].  The 48h soak collects [would_reject] cardinality so
    we can identify dashboard / internal callers that need their token wiring
    fixed before strict mode lands. *)

type t = Off | Dry_run | Strict

val current : unit -> t
(** Read [MASC_AUTH_STRICT] from the environment.  Unknown / missing values
    default to [Dry_run] so that operator omissions do not silently disable
    measurement. *)

val of_string : string -> t
(** Pure parser exposed for unit tests.  Accepts ["off" | "0" | "false" |
    "dry_run" | "dry-run" | "strict" | "1" | "true"], case-insensitive.
    Any other input returns [Dry_run] (fail-open for telemetry, fail-closed
    promotion happens in Phase B). *)

val to_label : t -> string
(** [to_label Off = "off"], [Dry_run = "dry_run"], [Strict = "strict"].
    Used as the Prometheus [mode] label so operators can break down
    [masc_auth_strict_would_reject_total] by mode. *)
