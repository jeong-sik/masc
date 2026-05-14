type t =
  | Diagnose
  | Draft
  | Execute
[@@deriving show, eq, ord]

let to_string = function
  | Diagnose -> "diagnose"
  | Draft -> "draft"
  | Execute -> "execute"
;;

let of_string = function
  | "diagnose" -> Ok Diagnose
  | "draft" -> Ok Draft
  | "execute" -> Ok Execute
  | s -> Error (Printf.sprintf "unknown execution mode: %s" s)
;;

let to_yojson v = `String (to_string v)

let of_yojson = function
  | `String s -> of_string s
  | j -> Error (Printf.sprintf "expected string, got %s" (Yojson.Safe.to_string j))
;;

let can_serve ~requested ~effective = compare effective requested <= 0
