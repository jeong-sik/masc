(** Approval dispatch dependency inversion ref.

    Tool dispatch can expose approval tools without importing the keeper
    approval queue.  A keeper-side composition module registers the backing
    implementation at module load. *)

(* TEL-OK: dependency-inversion ref module — telemetry lives in the
   registered backing dispatch ([Keeper_tool_in_process_runtime]). *)
let dispatch : (name:string -> args:Yojson.Safe.t -> string option) ref =
  ref (fun ~name:_ ~args:_ -> None)
;;
