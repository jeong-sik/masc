type 'scope t =
  | Empty
  | Rows of { scope : 'scope; keeper : string; rows : int list }

let empty = Empty

let of_rows ~scope ~keeper = function
  | [] -> Empty
  | rows -> Rows { scope; keeper; rows }

let equal ~same_scope left right =
  match left, right with
  | Empty, Empty -> true
  | Rows a, Rows b ->
      same_scope a.scope b.scope
      && String.equal a.keeper b.keeper
      && List.equal Int.equal a.rows b.rows
  | Empty, Rows _ | Rows _, Empty -> false

let contains ~same_scope ~scope ~keeper ~row = function
  | Empty -> false
  | Rows frame ->
      same_scope frame.scope scope
      && Option.exists (String.equal frame.keeper) keeper
      && List.mem row frame.rows
