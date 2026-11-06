(** How a run is bound to its original request, and how a worker is bound to a
    journal.

    [canonical_entry] loads the canonical async request of a request id and
    checks it against the source. [original_named_binding], [named_admission]
    and [named_binding] give the composition a named run was admitted with,
    and [resolved_named_result] returns the terminal entry and the resolution
    of a named run an operator resolved. [validate_nested_producer] checks the
    sealed parent behind a nested producer, and [nested_parent_accepted] tells
    whether that parent accepted the child. [child_observation] says whether a
    child is observed to recover its acceptance or to read its result,
    [accepted_child_binding] loads the composition a child accepted, and
    [validate_child_links] checks the child links of a journal against its
    nodes. [bind_expected_owner] makes a request the owner of the journal once
    the expected previous owner is proven terminal, and [bind_request] checks
    the journal and a queued request, binds it and returns a worker.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model

val canonical_entry :
  t ->
  string ->
  (Keeper_msg_async.entry, error) result

val original_named_binding :
  t ->
  state ->
  (Keeper_composition_dependency.composition, error)
  result

val named_admission : t ->
  (Keeper_composition_dependency.composition option, error) result

val named_binding : t -> (Keeper_composition_dependency.composition, error) result

val resolved_named_result :
  t ->
  state ->
  Keeper_composition_dependency.composition ->
  ((Keeper_msg_async.entry * resolution)
   option, error)
  result

val validate_nested_producer :
  t ->
  (unit, error) result

type child_observation = Acceptance_recovery | Result_observation

val accepted_child_binding :
  observation:child_observation ->
  base_path:string ->
  child_link ->
  (Keeper_composition_dependency.composition, error)
  result

val validate_child_links :
  t ->
  child_link Map.Make(String).t ->
  node_record Map.Make(String).t ->
  (unit, error) result

val nested_parent_accepted :
  t ->
  (bool, error) result

val bind_expected_owner :
  t ->
  request_id:string ->
  expected:binding option ->
  expected_terminal:Keeper_msg_async.entry option ->
  expected_nodes:node_record
                 Map.Make(String).t option ->
  expected_children:child_link
                    Map.Make(String).t option ->
  (worker,
   error)
  result

val bind_request : t -> request_id:string -> (worker, error) result
