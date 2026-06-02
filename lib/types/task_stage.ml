(** Task_stage — Typed task progress labels.

    Advisory order: decompose → inspect → implement → verify → review.
    Labels are non-authoritative metadata; review and reclassification must
    not be blocked by a previous label. *)

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
  | other ->
      Error
        (Printf.sprintf "task stage must be a string (received %s)"
           (Json_util.kind_name other))

let all = [Decompose; Inspect; Implement; Verify; Review]

let can_transition ~current:_ ~target:_ = true

let validate_transition ~current:_ ~target:_ = Ok ()

let initial = Decompose
