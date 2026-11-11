(** Terminal dispositions of the HITL exact-output flow, the counter that
    records them, and the run outcome a finished flow reports to the exact-lane
    run registry. [Hitl_summary_worker] includes this module. *)

open Keeper_approval_queue_rules_types

(** Every terminal disposition of the HITL exact-output flow.

    Closed on purpose. These were 27 string literals spread over 37 call
    sites, so a branch added later could reach the metric — and any consumer
    derived from it — without the compiler asking. A variant makes each
    derivation an exhaustive match, so the next branch stops the build
    until it is classified. The metric label text is unchanged: it is
    derived here rather than restated at each site. *)
type flow_outcome =
  | Ok_summary
  | Ok_summary_cli
  | Source_resolved
  | Identity_unbound
  | Identity_unbound_source_changed
  | Terminal_sync_unconfirmed
  | Terminal_persistence_failure
  | Terminal_rejected
  | Provenance_mismatch
  | Domain_invalid_output
  | Attempt_replay
  | Attempt_start_failed
  | Measurement_start_failed
  | Measurement_callback_failed
  | Candidates_exhausted
  | Bind_failed
  | Release_failed
  | Execution_failed
  | Cli_slots_exhausted
  | Cli_released_without_binding
  | Cli_walk_fell_back
  | Slots_held
  | Cli_release_unconfirmed
  | Cli_bind_unconfirmed
  | Cli_bind_failed
  | Cancellation
  | Cancellation_settlement_failed
  | Crashed

val outcome_label : flow_outcome -> string

val with_outcome_sink : flow_outcome option ref -> (unit -> 'a) -> 'a

val next_observed_outcome :
  flow_outcome option -> flow_outcome -> flow_outcome option

val record_outcome : flow_outcome -> unit

val run_outcome_of_observed_summary :
  last_outcome:flow_outcome option ->
  hitl_context_summary option ->
  Exact_lane_run_registry.outcome * Yojson.Safe.t
