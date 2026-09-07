(** Repetition evidence partitioned by durable invocation identity.
    This module does not infer an invocation from prompt text, checkpoint
    presence, task IDs, or provider attempts. Producers supply identity. *)

module Id : sig
  type t
  val direct_operation : Keeper_chat_operation.Operation_id.t -> t
  val autonomous_admission : Uuidm.t -> t
  val equal : t -> t -> bool
  val to_json : t -> Yojson.Safe.t
  val of_json : Yojson.Safe.t -> (t, string) result
end

type admission = Fresh of Id.t | Resume of Id.t
type observation
type t
type error =
  | Invalid_snapshot of string
  | Invalid_observation of string
  | Unknown_scope of Id.t
  | Restore_target_conflict

val error_to_string : error -> string
val observation_of_call : Keeper_agent_result.tool_call_detail -> (observation, error) result
(** Validates and canonicalizes hashes before creating a recordable value. *)
val empty : t
val active : t -> Id.t option
val admit : t -> admission -> (t, error) result
(** Fresh is idempotent for an existing identity: it never clears evidence.
    Resume requires that exact scope to have been admitted. Admitting B keeps
    A, including when the process later restores this checkpoint. *)
val record : t -> scope:Id.t -> observation -> (t, error) result
(** One newly observed execution, not replay-safe ingestion. The caller owns
    callback delivery identity and serializes load/admit/record/save; individual
    Context get/set locks do not make that sequence a transaction. *)
val tool_calls : t -> scope:Id.t -> (Keeper_agent_result.tool_call_detail list, error) result
(** Only repetition fields are restored, newest first. They are observations
    for the detector, not current-turn receipt or execution-outcome evidence. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
val load : Agent_core.Context.t -> (t, error) result
(** Missing key means no scopes have been recorded. Malformed present data is
    an error, never empty state. A subsequent Resume of a missing scope fails. *)
val save : Agent_core.Context.t -> t -> unit
(** Stores the immutable projection in Context.Session. The caller must commit
    the owning checkpoint before claiming crash durability. This function is
    not a durable child-acceptance or cross-store transaction. *)

val restore : source:Agent_core.Context.t -> target:Agent_core.Context.t -> (t, error) result
(** Explicitly restore the checkpoint projection into a newly created runtime
    context, or replay an identical projection. A different or malformed
    existing target is an error and remains unchanged. An absent source cannot
    clear a populated target. Callers serialize this operation. This does not
    supply the separate official-client or durable child-parent stores. *)

module Execution : sig
  type t
  val direct_operation : Keeper_chat_operation.Operation_id.t -> t
  (** Allocate once from the claimed operation, outside provider retry loops.
      Direct operations interrupted by process restart remain terminal under
      the owner store contract; this does not resurrect their execution. *)
  val prepare : t -> source:Agent_core.Context.t -> target:Agent_core.Context.t ->
    (Keeper_agent_result.tool_call_detail list, error) result
  (** First attempt loads and admits the direct scope. Later attempts reuse
      its observations even if the previous provider returned no checkpoint.
      Returns only this scope's prior calls, excluding other work. *)
  val observe : t -> target:Agent_core.Context.t -> Keeper_agent_result.tool_call_detail -> unit
  (** Called by the serialized tool observer before checkpoint capture. Records
      validation failures explicitly; [failure] must stop later provider calls.
      The owner serializes prepare/observe and terminates old attempt callbacks
      before preparing a new attempt. Context projection alone is not disk I/O. *)
  val failure : t -> error option
end
