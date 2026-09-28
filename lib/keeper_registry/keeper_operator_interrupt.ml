exception Operator_interrupt

let rec is_operator_interrupt = function
  | Operator_interrupt -> true
  | Eio.Cancel.Cancelled inner -> is_operator_interrupt inner
  | Stdlib.Fun.Finally_raised inner -> is_operator_interrupt inner
  | Eio.Exn.Multiple [] -> false
  | Eio.Exn.Multiple members ->
    List.for_all (fun (member, _backtrace) -> is_operator_interrupt member) members
  | _ -> false
