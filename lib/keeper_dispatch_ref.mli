(** RFC-0182 §3.1 — keeper dispatch dependency inversion ref.

    Same pattern as [Workspace_dispatch_ref].
    [Keeper_tool_surface] lives in lib/ (late in module order) but is the
    natural home of keeper workspace tools.  Importing it from
    [Keeper_tool_in_process_runtime] (early in lib/keeper) would close
    a cycle.

    Resolution: register ctx-free entry points from [Keeper_tool_surface] into
    the ref at module load.  [Keeper_tool_in_process_runtime] reads the
    ref at dispatch time.

    The [~agent_name] parameter carries the caller keeper's agent name
    (typically [meta.agent_name]) so tools like [masc_keeper_status]
    that fall back to "self" when the [name] arg is empty can resolve
    the right target.

    RFC-0182 Phase 5 PR-A.2 extension: optional Eio resource params
    [?sw] / [?clock] / [?proc_mgr] / [?net] / [?mcp_session_id] for
    Eio-bound tools (masc_keeper_msg, masc_keeper_up,
    masc_keeper_sandbox_status, masc_keeper_create_from_persona).
    Existing registrations accept and ignore them.  The trailing
    [unit] argument is required so the OCaml compiler can determine
    when the optional defaults apply. *)

type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  continue:(unit -> Tool_result.result option) ->
  Tool_result.result option
(** Caller-owned boundary injected into concrete effect handlers. A handler
    that performs an external effect invokes this callback with its exact
    operation and complete input; read-only handlers do not invoke it. *)

val dispatch
  : (config:Workspace.config
     -> agent_name:string
     -> ?sw:Eio.Switch.t
     -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
     -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
     -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
     -> ?mcp_session_id:string
     -> ?authorize_external_effect:external_effect_authorizer
     -> name:string
     -> args:Yojson.Safe.t
     -> unit
     -> Tool_result.result option)
      ref
