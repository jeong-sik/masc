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
[@@deriving show, eq, ord]

let to_string = function
  | Decompose -> "decompose"
  | Inspect -> "inspect"
  | Implement -> "implement"
  | Verify -> "verify"
  | Review -> "review"

let of_string = function
  | "decompose" -> Ok Decompose
  | "inspect" -> Ok Inspect
  | "implement" -> Ok Implement
  | "verify" -> Ok Verify
  | "review" -> Ok Review
  | s -> Error (Printf.sprintf "unknown task stage: %s" s)

let to_yojson t = `String (to_string t)

let of_yojson = function
  | `String s -> of_string s
  | _ -> Error "task stage must be a string"

let all = [Decompose; Inspect; Implement; Verify; Review]

let can_transition ~current ~target =
  compare target current >= 0

let validate_transition ~current ~target =
  if can_transition ~current ~target then Ok ()
  else
    Error (Printf.sprintf "cannot go backward from %s to %s"
      (to_string current) (to_string target))

let initial = Decompose
