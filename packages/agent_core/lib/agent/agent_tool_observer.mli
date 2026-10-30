(** One live consumer per journal. Audiences are explicitly registered per
    Agent run, retained until scope teardown. Delivery acknowledges one source
    occurrence at a time; an ordinary failure retains the last cursor. *)
val create :
  publish:(Event_bus.t -> Event_bus.event -> unit) ->
  Execution_agent_scope.t -> Execution_context.tool_observer
