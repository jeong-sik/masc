(** Application-owned Agent Core execution journal capability. Installed once
    at server bootstrap and released with the root switch. Individual Keeper
    calls share this capability; they never create their own domain pool. *)

type initialization_error =
  | Already_initialized
  | Core_initialization_failed of Agent_core.Error.t

val initialization_error_to_string : initialization_error -> string

val initialize :
  sw:Eio.Switch.t -> domain_mgr:_ Eio.Domain_manager.t -> domain_count:int ->
  (unit, initialization_error) result
(** [domain_count] comes from the host's resolved executor resource policy. *)

val get : unit -> Agent_core.Agent.execution_runtime option
(** [None] means bootstrap has not installed the runtime, or its root switch
    has released it. Durable callers report this absence rather than silently
    running without a journal. *)
