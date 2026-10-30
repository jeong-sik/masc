(** Private fiber-local authority for recursive Agent runs inside Tool effects. *)

val with_child_scope_factory
  :  (agent_name:string -> (Execution_agent_scope.t, Execution_agent_scope.error) result)
  -> (unit -> 'a)
  -> 'a

val child_scope_factory
  :  unit
  -> (agent_name:string -> (Execution_agent_scope.t, Execution_agent_scope.error) result)
       option

val with_agent_scope : Execution_agent_scope.t -> (unit -> 'a) -> 'a
val agent_scope : unit -> Execution_agent_scope.t option
val with_provider_attempt : Execution_agent_scope.provider_attempt -> (unit -> 'a) -> 'a
val provider_attempt : unit -> Execution_agent_scope.provider_attempt option
val with_resume_once : (unit -> 'a) -> 'a
val take_resume_once : unit -> bool

type tool_observer =
  { register : run_id:Execution_event.Run_id.t -> event_bus:Event_bus.t option -> unit
  ; settled_observers : Tool_contract.Occurrence.t -> unit
  ; flush : unit -> unit
  }
val with_tool_observer : tool_observer -> (unit -> 'a) -> 'a
val tool_observer : unit -> tool_observer option
val flush_tool_observations : unit -> unit
val settle_tool_observers : Tool_contract.Invocation.t -> unit
