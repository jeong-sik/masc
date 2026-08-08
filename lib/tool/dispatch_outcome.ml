(* A dispatch is handled when the canonical handler returns a typed result.
   Missing handlers remain distinct so callers cannot mistake absence for a
   failed execution. *)

type t =
  | Handled
  | No_handler
[@@deriving show, eq]

(* The dispatch paths all decide the outcome from the same thing: whether
   the handler produced a result. Deriving it here keeps that decision, and
   the label it maps to, in one place. *)
let of_result_option = function
  | Some _ -> Handled
  | None -> No_handler
;;

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
