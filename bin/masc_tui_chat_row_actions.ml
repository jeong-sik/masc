type 'scope approval = {
  scope : 'scope;
  keeper : string;
  request_id : string;
  tool_call_id : string;
  approval_id : string;
}

type 'scope t =
  | Empty
  | Rows of {
      scope : 'scope;
      keeper : string;
      rows : int list;
      approval : 'scope approval option;
    }

let empty = Empty

let of_rows ~scope ~keeper = function
  | [] -> Empty
  | rows -> Rows { scope; keeper; rows; approval = None }

let with_approval approval = function
  | Empty ->
      Rows { scope = approval.scope; keeper = approval.keeper; rows = [];
             approval = Some approval }
  | Rows frame -> Rows { frame with approval = Some approval }

let approval = function
  | Empty -> None
  | Rows frame -> frame.approval

let same_approval ~same_scope left right =
  same_scope left.scope right.scope
  && String.equal left.keeper right.keeper
  && String.equal left.request_id right.request_id
  && String.equal left.tool_call_id right.tool_call_id
  && String.equal left.approval_id right.approval_id

let equal ~same_scope left right =
  match left, right with
  | Empty, Empty -> true
  | Rows a, Rows b ->
      same_scope a.scope b.scope
      && String.equal a.keeper b.keeper
      && List.equal Int.equal a.rows b.rows
      && Option.equal (same_approval ~same_scope) a.approval b.approval
  | Empty, Rows _ | Rows _, Empty -> false

let contains ~same_scope ~scope ~keeper ~row = function
  | Empty -> false
  | Rows frame ->
      same_scope frame.scope scope
      && Option.exists (String.equal frame.keeper) keeper
      && List.mem row frame.rows
