(** Task_stage — Typed coding_task stage gates.

    Canonical order: decompose → inspect → implement → verify → review.
    Forward and same-stage transitions are allowed; backward transitions
    are forbidden to prevent skipping verification. *)

type t =
  | Decompose
  | Inspect
  | Implement
  | Verify
  | Review
[@@deriving show]

let to_string = function
  | Decompose -> "decompose"
  | Inspect -> "inspect"
  | Implement -> "implement"
  | Verify -> "verify"
  | Review -> "review"
;;

let of_string = function
  | "decompose" -> Ok Decompose
  | "inspect" -> Ok Inspect
  | "implement" -> Ok Implement
  | "verify" -> Ok Verify
  | "review" -> Ok Review
  | s -> Error (Printf.sprintf "unknown task stage: %s" s)
;;

let to_yojson t = `String (to_string t)

let of_yojson = function
  | `String s -> of_string s
  | _ -> Error "task stage must be a string"
;;

let all = [ Decompose; Inspect; Implement; Verify; Review ]

let index = function
  | Decompose -> 0
  | Inspect -> 1
  | Implement -> 2
  | Verify -> 3
  | Review -> 4
;;

let can_transition ~current ~target = index target >= index current

let validate_transition ~current ~target =
  if can_transition ~current ~target
  then Ok ()
  else
    Error
      (Printf.sprintf
         "cannot go backward from %s to %s"
         (to_string current)
         (to_string target))
;;

let initial = Decompose
