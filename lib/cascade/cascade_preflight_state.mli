(** Cascade preflight unhealthy-skip escalation state.

    Tracks repeated [preflight skipped N unhealthy ...] events per
    (tier_group, provider, reason) fingerprint. After [threshold_disable]
    consecutive skips of the same fingerprint, the provider is registered
    in an in-memory disabled list and a single ERROR-class escalation is
    emitted (instead of a WARN per skip).

    A successful health recovery (caller invokes
    [reset_on_health_recovery]) clears all fingerprints for that provider
    and removes it from the disabled list, emitting one INFO transition.

    {1 Design notes}

    - Routing semantics are preserved: the disabled list is advisory.
      Callers may still attempt the provider; this module only changes
      the {e log-level cadence}, not routing.
    - State is in-memory only (per-process). Survives across cascade
      attempts in one keeper-server lifetime; rebuilt at restart.
    - Closed sum types only, no catch-all match.

    {1 References}

    - MASC/OAS Error-Warn Reduction Goal — 2026-05-18 §P3 (provider
      cascade exhaustion).
    - System log slice 2026-05-18, last 30min:
      [strict_tool_candidates: preflight skipped 1 unhealthy] x35,
      [glm-coding-with-spark: preflight skipped 1 unhealthy] x12. *)

(** Reason for a single preflight unhealthy-skip event. Closed sum,
    extend by adding a constructor (compiler enforces exhaustive
    match downstream). *)
type reason =
  | Health_check_failed_repeatedly
      (** Local-endpoint /health probe failed on the immediately
          preceding cycle; same provider URL keeps failing. *)
  | Permanent_unhealthy
      (** Endpoint advertises a non-recoverable status (e.g. 410,
          model-not-found, configuration error). *)
  | Transient_unhealthy
      (** Endpoint failed but the failure class is expected to
          self-heal (e.g. cold-start, brief network blip). *)
  | Rate_limited_long_window
      (** Endpoint is healthy but currently rate-limited; the limit
          window is long enough to count as a preflight skip. *)

(** Fingerprint of a single skip event. *)
type fingerprint = {
  tier_group : string;  (** Cascade name (e.g. ["strict_tool_candidates"]). *)
  provider : string;  (** Provider key or endpoint URL. *)
  reason : reason;
}

(** Outcome of [record]: [`First] means this is a brand-new
    fingerprint (or just-reset); [`Repeated n] means [n]th occurrence
    (1-based after the first, so n>=2) but threshold not yet reached;
    [`Threshold_disable n] means the fingerprint crossed
    [threshold_disable] (n is the consecutive count, n=threshold) — the
    caller should emit a single ERROR escalation and add the provider
    to the disabled list. Subsequent matching records return
    [`Already_disabled] until [reset_on_health_recovery] is called. *)
type record_outcome =
  [ `First
  | `Repeated of int
  | `Threshold_disable of int
  | `Already_disabled
  ]

(** Default consecutive-skip threshold. Crossing this triggers
    [`Threshold_disable]. *)
val default_threshold : int

(** Opaque tracker handle. The module exposes a process-singleton
    [global], but creating local instances is supported for tests. *)
type t

(** Create a fresh tracker. Tests should call this for isolation
    instead of using [global]. [threshold] defaults to
    [default_threshold]. *)
val create : ?threshold:int -> unit -> t

(** Process-singleton tracker used by production code paths. *)
val global : t

(** Record one preflight unhealthy-skip event. Returns the outcome,
    which the caller uses to decide log level and disable-list
    registration. Increments
    [masc_cascade_preflight_unhealthy_skip_total] (always) and
    [masc_cascade_provider_disabled_total] (on the [`Threshold_disable]
    transition). *)
val record :
  t -> tier_group:string -> provider:string -> reason:reason -> record_outcome

(** True iff the provider is currently in the disabled list (i.e. some
    fingerprint crossed threshold and recovery has not happened yet). *)
val is_disabled : t -> provider:string -> bool

(** Clear all fingerprints for the given provider and remove it from
    the disabled list. Returns [true] iff the provider was previously
    disabled (callers use this to emit a single INFO line on
    transition). *)
val reset_on_health_recovery : t -> provider:string -> bool

(** Snapshot of currently disabled providers. Order is unspecified;
    callers should sort for stable output. *)
val disabled_providers : t -> string list

(** Render a [reason] as a stable, kebab-case slug for log
    interpolation and metric labels. *)
val reason_slug : reason -> string

(** Reset the entire tracker to its initial state. Test-only helper. *)
val reset_for_test : t -> unit
