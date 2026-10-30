(** Reconstruct the repetition observations lost between durable ToolResult
    settlement and the Keeper checkpoint. No handler, gate, or observer runs. *)
type error =
  | Scope_mismatch
  | Seed_observations_changed
  | Checkpoint_observation_not_settled
  | Invalid_settled_result
  | Unsupported_result_provenance
  | Repetition_error of Keeper_repetition_snapshot.error

val error_to_string : error -> string

val reconcile :
  ?base_path:string ->
  scope:Keeper_execution_scope_id.t ->
  seed:Keeper_repetition_snapshot.t ->
  checkpoint:Keeper_repetition_snapshot.t ->
  settled:Agent_core.Agent.Execution_projection.settled_tool_invocation list ->
  unit -> (Keeper_repetition_snapshot.t, error) result
(** The immutable native seed must remain the exact suffix of this scope's
    checkpoint observations. Each observation after that seed consumes one
    canonical executed occurrence, preserving duplicates and checkpoint order.
    Missing observations are appended in canonical settlement order; their lost
    live observer order is not inferred. Unrelated scopes stay unchanged.
    Admission/validation failures do not count as handler observations. *)
