type rank =
  | Pending_confirmation
  | Action_result
  | Read_failure
  | Stale_observation
  | Next_schedule

(* RFC tui-one-screen-grammar §2, in its order. *)
let position = function
  | Pending_confirmation -> 0
  | Action_result -> 1
  | Read_failure -> 2
  | Stale_observation -> 3
  | Next_schedule -> 4

let compare_rank left right = Int.compare (position left) (position right)

type 'a shown = { lead : 'a; more : int }

let choose ~rank notices =
  match List.stable_sort (fun left right -> compare_rank (rank left) (rank right)) notices with
  | [] -> None
  | lead :: rest -> Some { lead; more = List.length rest }
