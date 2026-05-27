(** RFC-0182 §3.1 — keeper dispatch dependency inversion ref.

    See [keeper_dispatch_ref.mli] for the rationale. *)

(* TEL-OK: dependency-inversion ref module — telemetry lives in the
   registered backing dispatch (Tool_keeper / Tool_keeper_ops handlers). *)
let dispatch
  : (config:Coord.config
     -> agent_name:string
     -> ?sw:Eio.Switch.t
     -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
     -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
     -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
     -> ?mcp_session_id:string
     -> name:string
     -> args:Yojson.Safe.t
     -> unit
     -> Tool_result.result option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ?sw:_ ?clock:_ ?proc_mgr:_ ?net:_ ?mcp_session_id:_ ~name:_ ~args:_ () -> None)
;;
