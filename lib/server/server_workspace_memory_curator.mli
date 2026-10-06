(** Server-owned changed-fact curation into the durable workspace ledger.
    A configured exact-output lane is required. *)
val start : sw:Eio.Switch.t -> base_path:string -> unit

(** Wake an existing owner, including after an explicit lane configuration
    change. This performs no storage or provider work in the caller. *)
type refresh = Queued | No_owner | Unavailable of string

val request : base_path:string -> refresh

val output_schema : Yojson.Safe.t

module For_testing : sig
  (** The production configuration predicate, with only provider execution
      and its input bound replaced by the fixture. *)
  val start_configured
    : sw:Eio.Switch.t
    -> base_path:string
    -> max_input_bytes:int
    -> execute:(rendered_prompt:string -> selected:Workspace_memory_ledger.pending_fact list
       -> ledger:Workspace_memory_ledger.t -> (Yojson.Safe.t * string, string) result)
    -> unit

  (** The lane run itself: measured HTTP slots as one exact-output flow.
      Runtime preparation rejects CLI slots until they expose a context window. *)
  val execute
    : resolved:Runtime_exact_output_registry.resolved_lane
    -> rendered_prompt:string
    -> selected:Workspace_memory_ledger.pending_fact list
    -> ledger:Workspace_memory_ledger.t
    -> (Yojson.Safe.t * string, string) result

  val start
    : sw:Eio.Switch.t
    -> base_path:string
    -> max_input_bytes:int
    -> execute:(rendered_prompt:string -> selected:Workspace_memory_ledger.pending_fact list
       -> ledger:Workspace_memory_ledger.t -> (Yojson.Safe.t * string, string) result)
    -> unit
  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end
