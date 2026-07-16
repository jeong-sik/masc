open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val keeper_model_tool_names : unit -> string list
val keeper_model_tool_schemas : unit -> Masc_domain.tool_schema list

(** Schema for the keeper_tool_search tool. *)
val keeper_tool_search_schema : Masc_domain.tool_schema

(** Replace injected MASC tool schemas.
    Startup calls this through [inject_masc_schemas]; runtime readers should
    use [masc_schemas_snapshot] rather than holding mutable state. *)
val set_masc_schemas : Masc_domain.tool_schema list -> unit

(** Immutable snapshot of injected MASC tool schemas. *)
val masc_schemas_snapshot : unit -> Masc_domain.tool_schema list

(** Injected masc_* tool names (populated at startup by [inject_masc_schemas]). *)
val injected_masc_tool_names : unit -> string list

(** Deduplicate tool names, preserving order. *)
val dedupe_tool_names : string list -> string list

(** Test-only hooks for the global tool-call recorder and descriptor routing. *)
module For_testing : sig
  type descriptor_route_kind =
    | Output
    | Invariant
    | Registered_only

  val descriptor_route_invariant_payload
    :  tool_name:string
    -> Keeper_tool_descriptor.t
    -> Yojson.Safe.t

  val descriptor_route_kind
    :  descriptor:Keeper_tool_descriptor.t
    -> output:string option
    -> descriptor_route_kind
end

(** Inject all masc_* schemas for keeper descriptor/registry surface filtering.
    Must be called once during server initialization. *)
val inject_masc_schemas : Masc_domain.tool_schema list -> unit

(** The dispatch result is the producer result itself.  No bridge-facing
    outcome enum is introduced between Keeper execution and {!Tool_result}. *)
type executed_tool_result = Keeper_tool_execution.t

(** Tag-based dispatch callback for masc_* tools without handler registry entries.
    Set at server init to [Keeper_tag_dispatch.dispatch]. Default: returns None.
    See #4579. *)

val registered_handler_schema_names : unit -> string list

(** Compute the keeper's sender identity for broadcasts.
    Guards against double "keeper-" prefix. See #5104. *)

val execute_keeper_tool_call_with_outcome
  :  config:Workspace.config
  -> meta:keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_work:working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(unit -> Keeper_tool_execution.t)
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> name:string
  -> input:Yojson.Safe.t
  -> unit
  -> executed_tool_result
(** [meta] is the immutable metadata of the exact registry entry admitted at
    the turn-resource boundary. Dispatch never resolves the Keeper name again;
    [publication_recovery] preserves that entry's exact owner identity while
    carrying the live runtime provider. File edit/write dispatch reads the
    provider only at the effect boundary. *)

val execute_keeper_tool_call
  :  config:Workspace.config
  -> meta:keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_work:working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(unit -> Keeper_tool_execution.t)
  -> name:string
  -> input:Yojson.Safe.t
  -> unit
  -> string
