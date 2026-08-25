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
