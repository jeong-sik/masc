(** Event-dispatch transition validators (RFC-0002 + RFC-0072 Phase 6).

    Companion to [Keeper_registry_fsm_validators]; all pure side-effect
    wrappers, no registry state touched. *)

open Keeper_registry_types

(** Validate that the paired lifecycle event's origin is allowed.
    Returns [Ok ()] when the origin authorizes the half-event,
    [Error (Precondition_violation _)] otherwise — message preserves
    the legacy text shape for log/metrics consumers. *)
val paired_lifecycle_origin :
  lifecycle_event_origin -> Keeper_state_machine.event
  -> (unit, Keeper_state_machine.transition_error) result

(** Validate a compaction_stage transition. Idempotent self-loops are
    accepted; the 3 spec-forbidden pairs raise
    [Compaction_transition_violation] with the typed
    [compaction_transition_spec_violation] payload. Counter:
    [metric_fsm_guard_violation] (action=compaction_transition, stage=guard). *)
val compaction_transition :
  from:packed_compaction_stage -> to_:packed_compaction_stage -> unit
