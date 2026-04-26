(** Keeper Measurement — Det/NonDet Boundary Types (RFC-0002).

    This module defines the snapshot types for the deterministic/non-deterministic
    boundary. The [measurement_snapshot] is an immutable record captured once per
    decision cycle. Everything downstream of this record is deterministic.

    Phase 1: types and serialization.
    Phase 4: pure [capture] function — accepts pre-computed values,
    returns [measurement_snapshot]. All I/O happens upstream in the caller. *)

(** {1 Threshold Parameters} *)

(** Frozen snapshot of all runtime-configurable thresholds.
    Captured once per decision cycle to eliminate TOCTOU windows
    where [Runtime_params.get] could return different values. *)
type threshold_params =
  { compaction_ratio_gate : float
  ; compaction_message_gate : int
  ; compaction_token_gate : int
  ; compaction_cooldown_sec : int
  ; handoff_threshold : float
  ; handoff_cooldown_sec : int
  ; auto_handoff_enabled : bool
  ; reflect_repetition_threshold : float
  ; plan_goal_alignment_threshold : float
  ; plan_response_alignment_threshold : float
  ; guardrail_repetition_threshold : float
  ; guardrail_goal_alignment_threshold : float
  ; guardrail_response_alignment_threshold : float
  ; guardrail_context_threshold : float
  ; max_consecutive_hb_failures : int
  ; max_consecutive_turn_failures : int
  ; model_ratio_multiplier : float
  ; model_handoff_multiplier : float
  }

(** {1 Sub-measurements} *)

type context_measurement =
  { context_ratio : float
  ; message_count : int
  ; token_count : int
  ; max_tokens : int
  }

type similarity_measurement =
  { repetition_risk : float
  ; goal_alignment : float
  ; response_alignment : float
  ; similarity_measurable : bool
    (** [false] when the turn lacked the user/assistant message pair (or goal horizon)
      needed to compute [goal_alignment] / [response_alignment] honestly. In that
      case the two similarity floats are sentinel [0.0] — distinguishable from a
      real measurement of [0.0] only by this flag. Gates that consume similarity
      must fail-closed when [similarity_measurable = false] (see Keeper_guard). *)
  }

type timing_measurement =
  { now_ts : float
  ; idle_seconds : int
  ; since_last_compaction_sec : float
  ; since_last_handoff_sec : float
  ; proactive_warmup_elapsed : bool
  }

type failure_measurement =
  { consecutive_hb_failures : int
  ; consecutive_turn_failures : int
  }

(** {1 Measurement Snapshot} *)

(** Immutable snapshot of all non-deterministic values at a single decision point.
    This record IS the det/nondet boundary.
    Everything upstream is impure measurement;
    everything downstream is pure guard evaluation. *)
type measurement_snapshot =
  { snapshot_id : string
  ; keeper_name : string
  ; generation : int
  ; timestamp : float
  ; thresholds : threshold_params
  ; context : context_measurement
  ; similarity : similarity_measurement
  ; timing : timing_measurement
  ; failures : failure_measurement
  }

(** {1 Capture} *)

(** Pure snapshot constructor — the det/nondet boundary.
    All I/O (clock reads, file reads, Runtime_params queries) must happen
    before calling [capture]. The returned record is fully deterministic. *)
val capture
  :  snapshot_id:string
  -> keeper_name:string
  -> generation:int
  -> timestamp:float
  -> thresholds:threshold_params
  -> context_ratio:float
  -> message_count:int
  -> token_count:int
  -> max_tokens:int
  -> repetition_risk:float
  -> goal_alignment:float
  -> response_alignment:float
  -> ?similarity_measurable:bool
  -> now_ts:float
  -> idle_seconds:int
  -> since_last_compaction_sec:float
  -> since_last_handoff_sec:float
  -> proactive_warmup_elapsed:bool
  -> consecutive_hb_failures:int
  -> consecutive_turn_failures:int
  -> unit
  -> measurement_snapshot

(** {1 Serialization} *)

val threshold_params_to_json : threshold_params -> Yojson.Safe.t
val measurement_snapshot_to_json : measurement_snapshot -> Yojson.Safe.t
