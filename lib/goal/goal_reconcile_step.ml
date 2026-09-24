type t =
  | Reconcile_proof
  | Rearm_proof

let to_string = function
  | Reconcile_proof -> "reconcile_proof"
  | Rearm_proof -> "rearm_proof"
;;

let of_string = function
  | "reconcile_proof" -> Some Reconcile_proof
  | "rearm_proof" -> Some Rearm_proof
  | _ -> None
;;
