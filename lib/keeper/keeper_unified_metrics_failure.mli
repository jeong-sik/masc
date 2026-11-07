(** Failure-path metric update for a unified keeper cycle. *)

(** How a cycle that ended without an answer ended. [Rested_cycle] is a
    provider quota refusal that stated its reset
    (RFC-turn-failure-visible-stop §2.4): a scheduled autonomous cycle records
    [Proactive_rested] for it, not [Proactive_error]. *)
type unanswered_end =
  | Failed_cycle
  | Rested_cycle

val update_metrics_from_failure :
  Keeper_meta_contract.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  ended:unanswered_end ->
  ?core_error:Agent_core.Error.t ->
  unit ->
  Keeper_meta_contract.keeper_meta

(** Adds resolved attempt token deltas and advances the usage cursor. Cost
    coverage is accumulated once from all actual readings by the terminal
    commit path, including attempts without readings. *)
val with_attempt_spend :
  Keeper_meta_contract.keeper_meta ->
  resolved:Keeper_turn_spend.resolved list ->
  usage_cursor:Keeper_usage_resolution.cursor option ->
  Keeper_meta_contract.keeper_meta
