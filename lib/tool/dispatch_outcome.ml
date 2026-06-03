(* RFC-0084 §3.3, §6 D3 — Typed tool dispatch outcome.
   See dispatch_outcome.mli for the contract.

   Collapsed from a 5-arm sum to the two arms the system actually
   produces ([Handled] / [No_handler]).  The dropped arms
   ([Rejected_by_capability], [Rejected_by_pre_hook], [Handler_error])
   had zero producers: capability rejection returns an error result
   (classified [Handled]), a pre-hook [Reject] becomes [Some error]
   (classified [Handled]), and handler exceptions are captured as
   [Some (make_err_of_exn ...)] (classified [Handled]).  Keeping
   unproduced arms made illegal states representable but never reached
   (CLAUDE.md anti-pattern #4). *)

type t =
  | Handled
  | No_handler
[@@deriving show, eq]

let to_string = function
  | Handled -> "handled"
  | No_handler -> "no_handler"
;;

let of_string = function
  | "handled" -> Some Handled
  | "no_handler" -> Some No_handler
  | _unknown -> None
;;

let all_arms = [ Handled; No_handler ]

let classify_result_option r =
  match r with
  | Some _ -> Handled
  | None -> No_handler
;;
