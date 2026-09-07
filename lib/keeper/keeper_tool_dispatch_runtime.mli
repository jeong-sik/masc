open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val keeper_model_tool_schemas : unit -> Masc_domain.tool_schema list

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

(** The dispatch result is the producer result itself.  No bridge-facing
    outcome enum is introduced between Keeper execution and {!Tool_result}. *)
type executed_tool_result = Keeper_tool_execution.t

val execute_keeper_tool_descriptor_for_capability_surface_with_outcome
  :  capability_surface:Keeper_capability_surface.t
  -> config:Workspace.config
  -> meta:keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_work:working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> descriptor:Keeper_tool_descriptor.t
  -> input:Yojson.Safe.t
  -> unit
  -> executed_tool_result

val execute_keeper_tool_call_for_capability_surface_with_outcome
  :  capability_surface:Keeper_capability_surface.t
  -> config:Workspace.config
  -> meta:keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> ctx_work:working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
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

module Compatibility : sig
  val execute_keeper_tool_descriptor_with_outcome
    :  config:Workspace.config
    -> meta:keeper_meta
    -> publication_recovery:
         Keeper_publication_recovery_availability.turn_context
    -> ctx_work:working_context
    -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
    -> ?sw:Eio.Switch.t
    -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
    -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
    -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> ?mcp_session_id:string
    -> ?continuation_channel:Keeper_continuation_channel.t
    -> ?gate_context:(unit -> Keeper_gate.causal_context)
    -> ?gate_grant:Keeper_gate.cycle_grant
    -> descriptor:Keeper_tool_descriptor.t
    -> input:Yojson.Safe.t
    -> unit
    -> executed_tool_result

  val execute_keeper_tool_call_with_outcome
    :  config:Workspace.config
    -> meta:keeper_meta
    -> publication_recovery:
         Keeper_publication_recovery_availability.turn_context
    -> ctx_work:working_context
    -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
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

  val execute_keeper_tool_call
    :  config:Workspace.config
    -> meta:keeper_meta
    -> publication_recovery:
         Keeper_publication_recovery_availability.turn_context
    -> ctx_work:working_context
    -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
    -> name:string
    -> input:Yojson.Safe.t
    -> unit
    -> string
end
(** Explicit metadata compatibility boundary for tests and callers without a
    Keeper turn. Production Keeper handlers cannot enter this module without
    naming the compatibility choice. *)
(** [meta] is the immutable metadata of the exact registry entry admitted at
    the turn-resource boundary. Dispatch never resolves the Keeper name again;
    [publication_recovery] preserves that entry's exact owner identity while
    carrying the live runtime provider. File edit/write dispatch reads the
    provider only at the effect boundary. *)
