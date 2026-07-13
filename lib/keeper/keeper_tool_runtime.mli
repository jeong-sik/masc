(** Runtime dispatch for descriptor-backed agent tools.

    [Keeper_tool_dispatch_runtime] owns cross-cutting execution bookkeeping. This module
    owns the descriptor-selected lowerer/handler route for first-class agent
    tools such as [Execute], [Read], [Grep], and [WebSearch]. *)

(* RFC-0182 Phase 5 PR-A: [sw] / [clock] / [proc_mgr] / [net] /
   [mcp_session_id] are optional Eio resource fields.  Eio-bound
   descriptor handlers (masc_keeper_msg, masc_keeper_up, etc.) check
   for [Some] and return a typed "Eio context not provided" failure
   when unset. *)
type context =
  { config : Workspace.config
  ; meta : Keeper_meta_contract.keeper_meta
  ; ctx_work : Keeper_types.working_context
  ; turn_sandbox_factory : Keeper_sandbox_factory.t option
  ; exec_cache : Masc_exec.Exec_cache.t option
  ; search_fn : unit -> Keeper_tool_execution.t
  ; sw : Eio.Switch.t option
  ; clock : float Eio.Time.clock_ty Eio.Resource.t option
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option
  ; mcp_session_id : string option
  ; continuation_channel : Keeper_continuation_channel.t option
    (** RFC-0320: originating connector conversation of the current turn;
        lets async tools (masc_fusion) route completion wakes back. *)
  ; gate_context : (unit -> Keeper_gate.causal_context) option
    (** Exact outer-turn evidence forwarded opaquely to the Keeper Gate. *)
  ; gate_grant : Keeper_gate.cycle_grant option
    (** Exact human decision delivered to this Keeper lane. Permission-capable
        handlers must match it against the normalized request before use. *)
  }

val descriptor_for_internal : string -> Keeper_tool_descriptor.t option

val handle :
  context ->
  descriptor:Keeper_tool_descriptor.t ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t option
