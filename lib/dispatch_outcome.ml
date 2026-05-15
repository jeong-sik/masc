(* RFC-0084 §3.3, §6 D3 — Typed 5-arm tool dispatch outcome.
   See dispatch_outcome.mli for the contract. *)

type t =
  | Handled
  | Rejected_by_capability of { missing : string list }
  | Rejected_by_pre_hook of { reason : string }
  | No_handler
  | Handler_error of { exn : string }

let to_string = function
  | Handled -> "handled"
  | Rejected_by_capability _ -> "rejected_by_capability"
  | Rejected_by_pre_hook _ -> "rejected_by_pre_hook"
  | No_handler -> "no_handler"
  | Handler_error _ -> "handler_error"
;;

let of_string = function
  | "handled" -> Some Handled
  | "rejected_by_capability" -> Some (Rejected_by_capability { missing = [] })
  | "rejected_by_pre_hook" -> Some (Rejected_by_pre_hook { reason = "" })
  | "no_handler" -> Some No_handler
  | "handler_error" -> Some (Handler_error { exn = "" })
  | _ -> None
;;

let all_arms =
  [ Handled
  ; Rejected_by_capability { missing = [] }
  ; Rejected_by_pre_hook { reason = "" }
  ; No_handler
  ; Handler_error { exn = "" }
  ]
;;

let classify_result_option ?exn r =
  match exn, r with
  | Some s, _ -> Handler_error { exn = s }
  | None, Some _ -> Handled
  | None, None -> No_handler
;;
