(** RFC-0313 W1 — pure per-runtime revisit pacing.

    A turn failure may change WHEN a runtime is next tried (the revisit
    deadline) and WHERE the next turn runs (whichever runtime is due
    first), never WHETHER the keeper exists. This module is the pure
    state for the "when": an immutable per-runtime map of revisit
    deadlines. It has no dependencies beyond the stdlib and performs no
    I/O; the shadow store ([Keeper_pacing_shadow]) owns process state
    and telemetry.

    Verified shape: specs/keeper-state-machine/KeeperPacing.tla —
    [on_failure] maps to [TurnFailure] (widening bounded by
    [policy.cap_sec], the [PacingBounded] invariant), [on_success] to
    [TurnSuccess], [next_turn_due] to the min-eligible scheduling rule
    (a keeper always has a finite next turn). *)

type policy =
  { base_sec : float (** first revisit delay after a failure *)
  ; multiplier : float (** widening factor per consecutive failure *)
  ; cap_sec : float (** hard bound: no revisit exceeds now + cap_sec *)
  }

val default_policy : policy
(** base 30s, x2 per consecutive failure, cap 3600s. Single named
    site for the shadow phase; RFC-0313 W3 moves the policy to
    config/runtime.toml [pacing] when pacing becomes enforcing. With
    these values the 2026-07-06 storm fixture window (300s) admits at
    most ~7 attempts per runtime vs the 1,002 recorded
    (test/fixtures/pacing_storm_20260706/). *)

type revisit =
  { eligible_at : float (** unix seconds; runtime may be tried at/after this *)
  ; consecutive : int
    (** consecutive failures on this runtime since its last success.
        Observability only — never compared against a threshold. *)
  }

type t
(** Pacing state for one keeper. Immutable. A runtime with no entry is
    eligible immediately. *)

val empty : t

val on_failure
  :  policy:policy
  -> runtime_id:string
  -> retry_after:float option
  -> now:float
  -> t
  -> t
(** Widen [runtime_id]'s revisit: delay = min(cap_sec,
    base_sec * multiplier^(consecutive-1)); a provider-supplied
    [retry_after] (clamped to [0, cap_sec]) replaces the computed
    delay. Never touches other runtimes. *)

val on_success : runtime_id:string -> t -> t
(** Clear [runtime_id]'s revisit (eligible immediately, consecutive
    reset). Other runtimes keep their deadlines. *)

val revisit_of : runtime_id:string -> t -> revisit option

val next_turn_due : catalog:string list -> now:float -> t -> float
(** Earliest time any runtime in [catalog] is eligible: [now] when some
    runtime has no entry or an expired deadline, otherwise the minimum
    [eligible_at]. An empty [catalog] yields [now] — the keeper always
    has a next turn. *)

val to_summary : t -> (string * revisit) list
(** Observability projection, sorted by runtime id. *)
