(** Runtime context and tool-call adaptation for the shared pure repetition
    snapshot. Producers supply invocation identity; no inference from history. *)
val observation_of_call : Keeper_tool_call_detail.t ->
  (Keeper_repetition_snapshot.observation, Keeper_repetition_snapshot.error) result
val tool_calls : Keeper_repetition_snapshot.t -> scope:Keeper_execution_scope_id.t ->
  (Keeper_tool_call_detail.t list, Keeper_repetition_snapshot.error) result
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
  val autonomous_admission : Uuidm.t -> t
  (** Allocate once from the UUID issued by the admitted autonomous Owner child.
      Carry this same execution through provider attempts; this constructor
      neither commits semantic admission nor grants checkpoint resume authority. *)
  val scope : t -> Keeper_execution_scope_id.t
  (** Original producer-supplied identity; never derived from a checkpoint. *)
  val prepare : t -> source:Agent_core.Context.t -> target:Agent_core.Context.t ->
    (Keeper_tool_call_detail.t list, Keeper_repetition_snapshot.error) result
  (** First direct attempt restores an absent/equal target before admission.
      An autonomous attempt retains shared Session scopes (including those of
      checkpointless official clients), merging source scopes only when any
      overlapping observations are equal. Malformed or conflicting evidence
      refuses without changing the target. Then admit the original scope,
      retaining every other scope but returning only its own observations.
      Later attempts reuse the same execution even when the provider returned
      no checkpoint. This projection does not grant pending-input authority. *)
  val observe : t -> target:Agent_core.Context.t -> Keeper_tool_call_detail.t -> unit
  (** Called by the serialized tool observer before checkpoint capture. Records
      validation failures explicitly; [failure] must stop later provider calls.
      The owner serializes prepare/observe and terminates old attempt callbacks
      before preparing a new attempt. Context projection alone is not disk I/O. *)
  val snapshot : t -> (Keeper_repetition_snapshot.t, Keeper_repetition_snapshot.error) result
  val resume : t -> Keeper_repetition_snapshot.t -> (unit, Keeper_repetition_snapshot.error) result
  val failure : t -> Keeper_repetition_snapshot.error option
end
