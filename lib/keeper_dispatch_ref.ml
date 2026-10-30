(** RFC-0182 §3.1 — keeper dispatch dependency inversion ref.

    See [keeper_dispatch_ref.mli] for the rationale. *)

(* TEL-OK: dependency-inversion ref module — telemetry lives in the
   registered backing dispatch (Keeper_tool_surface / Keeper_tool_surface_ops handlers). *)
type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  continue:(unit -> Tool_result.result option) ->
  Tool_result.result option

let dispatch
  : (config:Workspace.config
     -> agent_name:string
     -> publication_recovery_provider:
          Keeper_publication_recovery_availability.provider
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
  =
  ref (fun ~config:_ ~agent_name:_ ~publication_recovery_provider:_ ?sw:_ ?clock:_ ?proc_mgr:_ ?net:_ ?mcp_session_id:_ ?authorize_external_effect:_ ~name ~args:_ () ->
    failwith
      (Printf.sprintf
         "keeper_dispatch_ref: dispatch called for tool %S before boot registration — \
          ensure Server_bootstrap registers the keeper dispatch backing"
         name))
;;
