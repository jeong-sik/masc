type t =
  | Low
  | Medium
  | High
  | Critical
[@@deriving show, eq, ord]

let to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"
;;

let of_string = function
  | "low" -> Ok Low
  | "medium" -> Ok Medium
  | "high" -> Ok High
  | "critical" -> Ok Critical
  | s -> Error (Printf.sprintf "unknown risk class: %s" s)
;;

let to_yojson v = `String (to_string v)

let of_yojson = function
  | `String s -> of_string s
  | j -> Error (Printf.sprintf "expected string, got %s" (Yojson.Safe.to_string j))
;;

let max_mode = function
  | Low -> Some Execution_mode.Execute
  | Medium -> Some Execution_mode.Execute
  | High -> Some Execution_mode.Draft
  | Critical -> None
;;
