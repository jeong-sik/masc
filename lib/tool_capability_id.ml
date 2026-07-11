type t =
  | Route of string
  | Board_operation of Tool_name.Board_name.t

let route name = Route name
let board_operation name = Board_operation name

let board_operation_opt = function
  | Board_operation name -> Some name
  | Route _ -> None
;;

let to_string = function
  | Route name -> "route:" ^ name
  | Board_operation name ->
    "board:" ^ Tool_name.Board_name.operation_name name
;;

let equal left right =
  match left, right with
  | Route left, Route right -> String.equal left right
  | Board_operation left, Board_operation right -> left = right
  | Route _, Board_operation _
  | Board_operation _, Route _ -> false
;;

let compare left right =
  match left, right with
  | Route left, Route right -> String.compare left right
  | Route _, Board_operation _ -> -1
  | Board_operation _, Route _ -> 1
  | Board_operation left, Board_operation right -> Stdlib.compare left right
;;
