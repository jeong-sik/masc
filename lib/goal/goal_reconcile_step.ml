type t =
  | Reconcile_proof
  | Rearm_proof
  | Read_original

let to_string = function
  | Reconcile_proof -> "reconcile_proof"
  | Rearm_proof -> "rearm_proof"
  | Read_original -> "read_original"
;;

let of_string = function
  | "reconcile_proof" -> Some Reconcile_proof
  | "rearm_proof" -> Some Rearm_proof
  | "read_original" -> Some Read_original
  | _ -> None
;;
