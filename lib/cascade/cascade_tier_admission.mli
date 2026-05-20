(** Cascade_tier_admission — per-tier inflight admission control.

    RFC-0153 Phase B.1. Provides a per-[tier_id] non-blocking
    admission counter that caps how many concurrent cascade attempts
    can occupy a tier at once. Designed to be the consumer of
    {!Cascade_saturation_signal} emissions from Phase A.2: when a
    tier saturates, this module rejects new admissions with a typed
    signal instead of letting N keepers stampede the same provider.

    Phase B.1 is the module + tests only. Phase B.2 wires it into
    {!Keeper_turn_driver.try_cascade} behind an env flag. The module
    has no global state; callers own a {!t} instance.

    Side-task starvation defence (RFC-0153 §6.8): every call to
    {!with_admission} must pass [~admission_policy]. There is no
    default — callers must choose [Required] (main keeper turn path)
    or [Bypass] (probe / memory summary / side task) explicitly. The
    OCaml type system enforces this at compile time.

    External validation:
    - Rust [tower::limit::ConcurrencyLimit] uses the same per-target
      semaphore pattern in production.
    - OpenClaw and Hermes do not have a tier-level admission concept
      (single-session model). MASC's multi-keeper concurrency is
      novel territory; see RFC-0153 §6.7 + §6.8.

    @since RFC-0153 Phase B.1 *)

(** {1 Types} *)

type tier_id = string
(** Stable identifier for a cascade tier (e.g. ["strict_tool_candidates"]).
    Matches the [tier-group.<name>] keys in [cascade.toml]. *)

type admission_policy =
  | Required
      (** Main keeper turn path. Admission is enforced — at saturation,
          {!with_admission} returns [Error
          (Cascade_saturation_signal.Inflight_capacity_full _)]. *)
  | Bypass
      (** Side task (cascade health probe, memory summary, watchdog).
          Admission is skipped entirely — the inflight counter is not
          incremented and capacity checks do not apply. Prevents
          side tasks from being starved by production traffic
          (RFC-0153 §6.8). *)

type t
(** Per-process admission state. Holds a map of [tier_id] to inflight
    counter + per-tier configured capacity. Thread-safe under Eio. *)

(** {1 Construction} *)

val create : ?default_max_inflight:int -> unit -> t
(** [create ?default_max_inflight ()] returns a fresh admission state.
    Tiers not explicitly {!configure}d use [default_max_inflight]
    (default: 8) for their capacity. *)

val configure : t -> tier_id:tier_id -> max_inflight:int -> unit
(** Pre-configure (or update) a tier's capacity. Safe to call before
    or during operation; updates take effect for subsequent
    admission decisions. Existing inflight count is preserved. *)

(** {1 High-level safe wrapper} *)

val with_admission :
  t ->
  tier_id:tier_id ->
  admission_policy:admission_policy ->
  (unit -> 'a) ->
  ('a, Cascade_saturation_signal.t) result
(** [with_admission t ~tier_id ~admission_policy f] is the safe
    wrapper for tier-bounded execution.

    Behaviour by policy:
    - [Bypass] — calls [f ()] immediately, returns [Ok (f ())]. Does
      not touch the inflight counter for [tier_id]. Used by probes,
      memory summary, and other side tasks.
    - [Required] — tries to acquire one admission slot in [tier_id].
      If capacity is available, [f ()] runs and the slot is released
      when [f] returns (whether normally or by exception). If
      capacity is full, returns
      [Error (Inflight_capacity_full { tier_id; max_inflight })]
      *without* calling [f].

    Exception safety: if [f] raises, the slot is released before
    the exception propagates. Release errors are swallowed (per
    masc-mcp finalizer convention) so the original exception is
    preserved. *)

(** {1 Lower-level API} *)

(** Outcome of a non-blocking admission attempt. *)
type try_decision =
  | Granted of { inflight_after_acquire : int; max_inflight : int }
  | Capacity_full of { inflight_at_check : int; max_inflight : int }

val try_acquire : t -> tier_id:tier_id -> try_decision
(** Non-blocking admission attempt. [Granted] increments the
    inflight counter and the caller MUST call {!release} exactly
    once. [Capacity_full] does not change state.

    This is the lower-level building block of {!with_admission}.
    Direct use is for callers that need to interleave admission with
    other concerns (e.g. trying another tier on capacity_full
    before deciding). Most callers should use {!with_admission}. *)

val release : t -> tier_id:tier_id -> unit
(** Decrement the inflight counter for [tier_id]. Idempotent at the
    floor — release on a zero-counter is a no-op (no negative
    inflight). Pairs 1:1 with a [Granted] from {!try_acquire}. *)

(** {1 Observability} *)

val current_inflight : t -> tier_id:tier_id -> int
(** Current inflight count for [tier_id], or 0 if the tier has
    never been seen. Read-only; intended for metrics and tests. *)

val configured_max : t -> tier_id:tier_id -> int
(** Configured capacity for [tier_id]. Returns the default if the
    tier has not been explicitly configured. Read-only. *)
