(** Server-owned changed-fact curation into the durable workspace ledger.
    A configured exact-output lane is required. *)
val start : sw:Eio.Switch.t -> base_path:string -> unit
(** Retained facts are reconsidered when the process registry becomes available,
    including an enabled declaration published after this owner parked. Off
    remains a new-work refusal; already accepted work can finish. *)

(** Wake an existing owner, including after an explicit lane configuration
    change. This performs no storage or provider work in the caller. *)
type refresh = Queued | No_owner | Unavailable of string

val request : base_path:string -> refresh

val output_schema : Yojson.Safe.t

module For_testing : sig
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
  val start_with_registry
    : sw:Eio.Switch.t
    -> base_path:string
    -> max_input_bytes:int
    -> execute:(rendered_prompt:string -> selected:Workspace_memory_ledger.pending_fact list
       -> ledger:Workspace_memory_ledger.t -> (Yojson.Safe.t * string, string) result)
    -> unit
  (** Keep the real registry admission and wake lifecycle; inject only the
      model execution and input bound. *)
  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end
