(** Approval dispatch dependency inversion ref.

    Tool dispatch can expose approval tools without importing the keeper
    approval queue.  A keeper-side composition module registers the backing
    implementation at module load. *)

let dispatch : (name:string -> args:Yojson.Safe.t -> string option) ref =
  ref (fun ~name:_ ~args:_ -> None)
;;
