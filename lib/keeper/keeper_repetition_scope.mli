(** Runtime context and tool-call adaptation for the shared pure repetition
    snapshot. Producers supply invocation identity; no inference from history. *)
val observation_of_call : Keeper_agent_result.tool_call_detail ->
  (Keeper_repetition_snapshot.observation, Keeper_repetition_snapshot.error) result
val tool_calls : Keeper_repetition_snapshot.t -> scope:Keeper_execution_scope_id.t ->
  (Keeper_agent_result.tool_call_detail list, Keeper_repetition_snapshot.error) result
(** Only repetition fields are restored, newest first. They are observations
    for the detector, not current-turn receipt or execution-outcome evidence. *)
val load : Agent_core.Context.t ->
  (Keeper_repetition_snapshot.t, Keeper_repetition_snapshot.error) result
(** Missing key means no scopes recorded. Malformed present data is an error. *)
val save : Agent_core.Context.t -> Keeper_repetition_snapshot.t -> unit
(** Writes Context.Session only; the caller commits the owning durable store. *)
val restore : source:Agent_core.Context.t -> target:Agent_core.Context.t ->
  (Keeper_repetition_snapshot.t, Keeper_repetition_snapshot.error) result
(** Restore into an absent key, or replay an equal projection. A different or
    malformed existing target stays unchanged. This is not a durable commit. *)

module Execution : sig
  type t
  val direct_operation : Keeper_chat_operation.Operation_id.t -> t
  (** Allocate once from the claimed operation, outside provider retry loops.
      Direct operations interrupted by process restart remain terminal under
      the owner store contract; this does not resurrect their execution. *)
  val prepare : t -> source:Agent_core.Context.t -> target:Agent_core.Context.t ->
    (Keeper_agent_result.tool_call_detail list, Keeper_repetition_snapshot.error) result
  (** First attempt loads and admits the direct scope. Later attempts reuse
      its observations even if the previous provider returned no checkpoint.
      Returns only this scope's prior calls, excluding other work. *)
  val observe : t -> target:Agent_core.Context.t -> Keeper_agent_result.tool_call_detail -> unit
  (** Called by the serialized tool observer before checkpoint capture. Records
      validation failures explicitly; [failure] must stop later provider calls.
      The owner serializes prepare/observe and terminates old attempt callbacks
      before preparing a new attempt. Context projection alone is not disk I/O. *)
  val snapshot : t -> (Keeper_repetition_snapshot.t, Keeper_repetition_snapshot.error) result
  val resume : t -> Keeper_repetition_snapshot.t -> (unit, Keeper_repetition_snapshot.error) result
  val failure : t -> Keeper_repetition_snapshot.error option
end
