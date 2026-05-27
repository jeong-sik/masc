(** Runtime dispatch for descriptor-backed agent tools.

    [Agent_tool_dispatch_runtime] owns cross-cutting execution bookkeeping. This module
    owns the descriptor-selected lowerer/handler route for first-class agent
    tools such as [Execute], [ReadFile], [SearchFiles], and [SearchWeb]. *)

(* RFC-0182 Phase 5 PR-A: [sw] / [clock] / [proc_mgr] / [net] /
   [mcp_session_id] are optional Eio resource fields.  Eio-bound
   descriptor handlers (masc_keeper_msg, masc_keeper_up, etc.) check
   for [Some] and return a typed "Eio context not provided" failure
   when unset. *)
type context =
  { config : Coord.config
  ; meta : Keeper_types.keeper_meta
  ; ctx_work : Keeper_types.working_context
  ; turn_sandbox_factory : Keeper_sandbox_factory.t option
  ; turn_sandbox_factory_git : Keeper_sandbox_factory.t option
  ; exec_cache : Masc_exec.Exec_cache.t option
  ; search_fn : query:string -> max_results:int -> Yojson.Safe.t
  ; sw : Eio.Switch.t option
  ; clock : float Eio.Time.clock_ty Eio.Resource.t option
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option
  ; mcp_session_id : string option
  }

val descriptor_for_internal : string -> Agent_tool_descriptor.t option

val handle :
  context -> descriptor:Agent_tool_descriptor.t -> args:Yojson.Safe.t -> string option

val handle_internal : context -> name:string -> args:Yojson.Safe.t -> string option
