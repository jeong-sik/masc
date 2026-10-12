(** Server-owned changed-fact curation into the durable workspace ledger.
    A configured exact-output lane is required. *)
val start : sw:Eio.Switch.t -> base_path:string -> unit
(** Retained facts are reconsidered when this lane's publication changes,
    including an enabled declaration published after this owner parked, and
    when a replacement fence that turned this owner away closes. Off remains a
    new-work refusal; already accepted work can finish. *)

(** Wake an existing owner, including after an explicit lane configuration
    change. This performs no storage or provider work in the caller. *)
type refresh = Queued | No_owner | Unavailable of string

val request : base_path:string -> refresh

val output_schema : Yojson.Safe.t

type execution_failure =
  | Input_too_large of string
  | Output_too_large of string
  | Execution_failed of string

module For_testing : sig
  (** The production configuration predicate, with provider execution and
      typed refusal evidence supplied by the fixture. *)
  val start_configured
    : sw:Eio.Switch.t
    -> base_path:string
    -> execute:(rendered_prompt:string -> selected:Workspace_memory_ledger.pending_fact list
       -> ledger:Workspace_memory_ledger.t -> (Yojson.Safe.t * string * Exact_lane_run_registry.usage option, execution_failure) result)
    -> summarize:(batch:Workspace_memory_briefing.batch -> (Yojson.Safe.t * string * Exact_lane_run_registry.usage option, execution_failure) result)
    -> unit

  (** The lane run itself: HTTP slots as one exact-output flow. *)
  val execute
    : resolved:Runtime_exact_output_registry.resolved_lane
    -> rendered_prompt:string
    -> selected:Workspace_memory_ledger.pending_fact list
    -> ledger:Workspace_memory_ledger.t
    -> (Yojson.Safe.t * string * Exact_lane_run_registry.usage option, string) result

  val start
    : sw:Eio.Switch.t
    -> base_path:string
    -> execute:(rendered_prompt:string -> selected:Workspace_memory_ledger.pending_fact list
       -> ledger:Workspace_memory_ledger.t -> (Yojson.Safe.t * string * Exact_lane_run_registry.usage option, execution_failure) result)
    -> summarize:(batch:Workspace_memory_briefing.batch -> (Yojson.Safe.t * string * Exact_lane_run_registry.usage option, execution_failure) result)
    -> unit
  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end
