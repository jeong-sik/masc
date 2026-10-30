(** Pure tool observations from committed canonical facts. No identity allocation,
    journal mutation, audience selection or delivery. *)
type error =
  | Missing_node of Execution_event.Node_id.t
  | Invalid_tool_fact of Execution_event.Node_id.t
  | Invalid_ancestry of Execution_event.Node_id.t
val error_to_string : error -> string
val project :
  find_node:(Execution_event.Node_id.t -> Execution_journal.node_view option) ->
  Execution_event.t -> (Event_bus.event option, error) result
