(** What the journal says about a finished request, and when a waiting
    continuation can resume.

    [observe_completion] reads an async entry and, when it belongs to a
    prepared run, the journal and its state, as a [completion_observation].
    [completion_observation_disposition] and [completion_disposition] give the
    [completion_disposition] of an observation or an entry, and
    [completion_pending] is false for [Canonical_completion] and true for
    [Recovery_pending] and [Unadmitted_attempt].
    [completion_result_notification] returns the [result_notification] that a
    canonical named completion owes the runs waiting for its result.
    [read_composition_result] is the reader of a composition result, and
    [continuation_readiness] uses it to tell whether a continuation is waiting
    or ready. [named_result_owner] and [observe_named_result] find the async
    entry that owns a named result.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model

type read_composition_result =
  base_path:string -> keeper_name:string -> Keeper_composition_dependency.composition -> (Keeper_composition_dependency.readiness,string) result

type result_notification =
  { base_path : string
  ; keeper_name : string
  ; dependency : Keeper_composition_dependency.t
  }

type completion_disposition =
  | Canonical_completion
  | Recovery_pending
  | Unadmitted_attempt

type completion_observation =
  { observed_disposition : completion_disposition
  ; observed_source : (t * state) option }

val observe_completion :
  base_path:string -> Keeper_msg_async.entry -> (completion_observation, error) result

val completion_observation_disposition : completion_observation -> completion_disposition

val completion_disposition :
  base_path:string -> Keeper_msg_async.entry -> (completion_disposition, error) result

val completion_result_notification :
  completion_observation -> (result_notification option, error) result

val completion_pending : base_path:string -> Keeper_msg_async.entry -> (bool, error) result

val continuation_readiness :
  read_composition_result:read_composition_result -> continuation -> (readiness, error) result

val named_result_owner :
  t -> Keeper_composition_dependency.composition -> (Keeper_msg_async.entry, error) result

val observe_named_result :
  base_path:string ->
  keeper_name:string ->
  Keeper_composition_dependency.composition ->
  (t * Keeper_msg_async.entry *
   resolution option,
   error)
  result
