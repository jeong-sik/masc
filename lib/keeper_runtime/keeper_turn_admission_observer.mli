(** Process-global, edge-triggered observer for fleet turn-admission.

    Every keeper calls {!decide_observed} each heartbeat cycle; a lock-free CAS
    on a single process-global phase makes exactly ONE keeper log each phase
    transition. A fleet-wide stall therefore produces ONE [Warn] at the episode
    start and ONE at the end (plus one if the blocking reason changes), instead
    of the per-keeper-per-cycle [Debug] flood the old inline gates emitted.

    The returned decision is {!Keeper_turn_admission.decide}'s, unchanged — the
    phase is observability only and never gates control flow, so a phase bug can
    only mislabel a log line, never stall a keeper. *)

type phase =
  | Admitting
  | Blocked_phase of { kind : string; since : float }

type edge =
  | No_edge
  | Entered_block of { kind : string }
  | Kind_changed of { from_kind : string; to_kind : string }
  | Resumed of { was_kind : string; blocked_for_sec : float }

(** Pure transition function. [admitted_kind] is [None] when admitted, or
    [Some kind] for the current blocking source. [now] stamps a new block's
    [since] and measures [blocked_for_sec] on resume. Exhaustive; exposed so
    the transition logic is testable without [Atomic]/[Log]/clock. *)
val classify : prev:phase -> admitted_kind:string option -> now:float -> phase * edge

(** Observe a decision: CAS-once on the global phase, emitting at most one
    [Warn] for the edge crossed. Exposed for tests; production reaches it via
    {!decide_observed}. *)
val observe : Keeper_turn_admission.decision -> unit

(** Compose then observe: runs {!Keeper_turn_admission.decide} and observes the
    result, returning the decision unchanged. *)
val decide_observed
  :  masc_root:string
  -> active_keepers:int
  -> unit
  -> Keeper_turn_admission.decision

val reset_for_tests : unit -> unit
