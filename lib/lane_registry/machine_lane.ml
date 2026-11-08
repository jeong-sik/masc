type t =
  | Msx
  | Dos
[@@deriving enumerate]

let to_wire = function
  | Msx -> "msx"
  | Dos -> "dos"
;;

let of_wire raw = List.find_opt (fun machine -> String.equal (to_wire machine) raw) all
