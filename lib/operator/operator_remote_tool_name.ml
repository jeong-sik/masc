type t =
  | Operator_snapshot
  | Operator_digest
  | Operator_action
  | Operator_confirm
  | Surface_audit

let to_string = function
  | Operator_snapshot -> "masc_operator_snapshot"
  | Operator_digest -> "masc_operator_digest"
  | Operator_action -> "masc_operator_action"
  | Operator_confirm -> "masc_operator_confirm"
  | Surface_audit -> "masc_surface_audit"
;;

let all =
  [ Operator_snapshot; Operator_digest; Operator_action; Operator_confirm; Surface_audit ]
;;

let all_strings = List.map to_string all
