(** RFC-0182 §3.1 — keeper dispatch dependency inversion ref.

    See [keeper_dispatch_ref.mli] for the rationale. *)

(* TEL-OK: dependency-inversion ref module — telemetry lives in the
   registered backing dispatch (Tool_keeper / Tool_keeper_ops handlers). *)
let dispatch
  : (config:Coord.config
     -> agent_name:string
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.result option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ~name:_ ~args:_ -> None)
;;
