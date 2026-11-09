type item =
  | Wake of Masc_tui_keeper_wakes.t
  | Turn of Masc_tui_keeper_turns.turn
  | Digest of float

let at = function
  | Wake wake -> Masc_tui_keeper_wakes.at wake
  | Turn turn -> turn.Masc_tui_keeper_turns.at
  | Digest at -> at
;;

let wakes_shown = 2

(* The order the events happen in when two of them carry one time. *)
let rank = function
  | Wake _ -> 0
  | Turn _ -> 1
  | Digest _ -> 2
;;

let compare_items left right =
  match Float.compare (at left) (at right) with
  | 0 -> Int.compare (rank left) (rank right)
  | order -> order
;;

let of_sources ~turns ~wakes ~digest_at =
  List.stable_sort compare_items
    (List.map (fun wake -> Wake wake) (List.take wakes_shown wakes)
     @ List.map (fun turn -> Turn turn) turns
     @ List.map (fun at -> Digest at) (Option.to_list digest_at))
;;
