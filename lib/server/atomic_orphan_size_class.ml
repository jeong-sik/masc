type t =
  | Empty
  | With_data

let to_label = function
  | Empty -> "empty"
  | With_data -> "with_data"
;;
