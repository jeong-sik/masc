(** The continuation of a run that waits for results: how a request is bound to
    it, and how its waits and lost nodes are proven.

    [waiting_continuation] reads the [continuation] a journal holds for its
    owner, or [None] when it has none. [continuation_base_path],
    [continuation_source], [continuation_request_id] and
    [continuation_dependencies] read its parts.
    [validate_predecessor_terminals] checks the terminal entries of the
    previous owners, and [bind_continuation] binds a request as the next
    owner. [child_admission_history] says whether the child runs of some nodes
    were never started, were admitted, or may have been admitted;
    [nodes_child_admission], [continuation_child_admission] and
    [child_admission] compute it from nodes, a continuation or a journal.
    [normalize_dependencies] normalizes a dependency list.
    [exact_waiting_dependencies] checks that the settled nodes of a waiting
    owner wait for exactly the given dependencies, [prior_result_wait] reads
    the wait the previous owners recorded, and [recoverable_lost_nodes] checks
    that the nodes of a lost owner can be recovered.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model

val validate_predecessor_terminals :
  continuation ->
  (unit, error) result

val bind_continuation : continuation -> request_id:string -> (worker, error) result

val continuation_base_path : continuation -> string

val continuation_source : continuation -> source

val continuation_request_id : continuation -> string

val continuation_dependencies : continuation -> Keeper_composition_dependency.t list

type child_admission_history = Untouched_child | Admitted_child | Admission_unconfirmed

val nodes_child_admission :
  node_record Map.Make(String).t ->
  node_ids:Keeper_tool_plan.Node_id.t list -> child_admission_history

val continuation_child_admission : continuation ->
  node_ids:Keeper_tool_plan.Node_id.t list -> child_admission_history

val child_admission : t -> node_ids:Keeper_tool_plan.Node_id.t list ->
  (child_admission_history, error) result

val normalize_dependencies : Keeper_composition_dependency.t list -> Keeper_composition_dependency.t list

val exact_waiting_dependencies :
  child_link Map.Make(String).t ->
  expected_owner:binding ->
  node_record Map.Make(String).t ->
  Keeper_composition_dependency.t list ->
  (Keeper_composition_dependency.t list, error) result

val prior_result_wait :
  t ->
  child_link Map.Make(String).t ->
  (binding *
   node_record Map.Make(String).t)
  list ->
  ((Keeper_composition_dependency.t list * Keeper_msg_async.entry list) option,
   error)
  result

val recoverable_lost_nodes :
  child_link Map.Make(String).t ->
  node_record Map.Make(String).t ->
  Keeper_composition_dependency.t list ->
  (unit, error) result

val waiting_continuation : t -> (continuation option, error) result
