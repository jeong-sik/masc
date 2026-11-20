type count = int

type width =
  | All
  | Units of count
  | Items of count

type offered =
  { units : int
  ; head_items : int
  }

type wider = offered

type breadth =
  | One_item
  | Wider of wider

(* The model's gate. A head of no unit carries no item: such a question is
   never made, so every count a wider question puts on a level is one or
   more. *)
let breadth offered =
  if offered.units > 1 || (Int.equal offered.units 1 && offered.head_items > 1)
  then Wider offered
  else One_item
;;

type passed =
  | Whole_units of int
  | Head_items of int

let passed offered : Librarian_log.within -> passed = function
  | Whole -> Whole_units offered.units
  | Item (_ : Librarian_unit.item_name) -> Head_items offered.head_items
;;

type range =
  { size : count
  ; left : count
  }

(* Innermost first. *)
type t =
  { units : range list
  ; items : range list
  }

let empty = { units = []; items = [] }

(* §7.6 "거절". Testing [left] alone would skip a range that was partly
   committed and refused for what is left, and ask the same width again. *)
let push level n =
  match level with
  | { size; left } :: (_ : range list) when Int.equal size n && Int.equal left n -> level
  | [] | _ :: _ -> { size = n; left = n } :: level
;;

(* An [Items _] question carries one unit, so only its items level grows. *)
let refused t ~asked (wider : wider) =
  let units =
    match asked with
    | All | Units (_ : count) -> push t.units wider.units
    | Items (_ : count) -> t.units
  in
  let items = if Int.equal wider.units 1 then push t.items wider.head_items else t.items in
  { units; items }
;;

let sub level passed =
  List.filter_map
    (fun range ->
       let left = range.left - passed in
       if left > 0 then Some { range with left } else None)
    level
;;

let committed t = function
  | Whole_units passed -> { units = sub t.units passed; items = [] }
  | Head_items passed -> { t with items = sub t.items passed }
;;

let width_of { size; left } = if Int.equal left size && size > 1 then size / 2 else left

let next t =
  match t.items, t.units with
  | range :: (_ : range list), (_ : range list) -> Items (width_of range)
  | [], range :: (_ : range list) -> Units (width_of range)
  | [], [] -> All
;;
