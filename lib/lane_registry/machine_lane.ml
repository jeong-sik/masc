type t =
  | Msx
  | Dos
[@@deriving enumerate]

let to_wire = function
  | Msx -> "msx"
  | Dos -> "dos"
;;
