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

(* The sort is stable, so events of one time keep the order the sources are
   joined in below: wakes, turns, digest. That is the order they happen in: a
   wake starts a turn and a digest follows the turns it digested. *)
let compare_items left right = Float.compare (at left) (at right)

let of_sources ~turns ~wakes ~digest_at =
  List.stable_sort compare_items
    (List.map (fun wake -> Wake wake) (List.take wakes_shown wakes)
     @ List.map (fun turn -> Turn turn) turns
     @ List.map (fun at -> Digest at) (Option.to_list digest_at))
;;
