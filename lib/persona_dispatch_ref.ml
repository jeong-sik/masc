(** RFC-0182 §3.1 — persona dispatch dependency inversion ref.

    See [persona_dispatch_ref.mli] for the rationale. *)

(* TEL-OK: dependency-inversion ref module — telemetry lives in the
   registered backing dispatch ([Keeper_persona] / [Keeper_persona_authoring]). *)
let dispatch
  : (name:string -> args:Yojson.Safe.t -> (bool * string) option) ref
  =
  ref (fun ~name:_ ~args:_ -> None)
;;
