(** Glue layer between [keeper_turn_slot] (the live admission semaphore)
    and the new admission router stack (PR-A/B/C of RFC-0026).

    This module is the swap-in point for PR-E.  It exposes a single
    decision function the heartbeat loop can call instead of the
    current global semaphore acquire path.  Behavior is gated by
    [MASC_ADMISSION_USE_NEW]:

      - unset / "false" / "0" : returns [Legacy_path], caller falls
        back to existing [Keeper_turn_slot.with_keeper_turn_slot].

      - "true" / "1"          : returns the new
        [Keeper_admission_router.decision], caller acts on
        Dispatch / Wait / Surface accordingly.

    Crucially, this module does NOT touch the existing semaphore code
    path.  The two systems coexist for the duration of A/B testing.
    Only after the [MASC_ADMISSION_USE_NEW] cohort reports a >= 95%
    skip-turn reduction (RFC-0026 §7 acceptance) does PR-E-2 remove
    the legacy code.

    What this module does NOT:

    - Build the bucket registry.  The heartbeat loop owns that and
      passes a [bucket_lookup] in.
    - Build the persona policy table.  Loaded once at startup from
      [admission.<keeper>] sub-tables in [cascade.toml] (PR-B-3 #1089).
      The loader is a separate module (PR-E-1.5) and supplies the
      [policy_lookup] function passed in here.
    - Manage the WFQ overflow queue itself.  When [decide] returns
      [Wait], the caller is responsible for [Keeper_wfq_overflow.enqueue]. *)

(** {1 Feature flag} *)

val use_new_admission : unit -> bool
(** Reads [MASC_ADMISSION_USE_NEW].  Returns [true] when the value is
    one of ["true"], ["1"], ["yes"] (case-insensitive).  Default
    [false] — legacy semaphore path.  Cached after first read so the
    flag does not flip mid-turn. *)

(** {1 Decision API} *)

type policy_lookup = string -> Keeper_admission_policy.t option
(** Looks up a per-keeper policy by [keeper_id].  Returns [None] for
    unknown keepers; the caller is expected to fall back to a default
    [shared] policy (RFC-0026 §3.6 surface semantics). *)

type outcome =
  | New_admission of Keeper_admission_router.decision
  (** New router returned a decision.  Caller dispatches /
      enqueues / surfaces per the inner variant. *)
  | Legacy_path
  (** Flag is off, or no policy is configured for this keeper.
      Caller falls through to the existing
      [Keeper_turn_slot.with_keeper_turn_slot]. *)

val decide :
  keeper_id:string ->
  policies:policy_lookup ->
  buckets:Keeper_admission_router.bucket_lookup ->
  outcome
(** Single entry point.  Sequence:

    1. Read [use_new_admission ()].  If false → [Legacy_path].
    2. Look up the persona policy via [policies keeper_id].
       If [None] → [Legacy_path] (unknown persona; safe fallback).
    3. Otherwise call [Keeper_admission_router.schedule] and wrap
       the result in [New_admission].

    Pure-ish: the only side effect is the bucket decrement inside
    [try_acquire] when Dispatch fires — same contract as the router
    itself.  No global mutation. *)
