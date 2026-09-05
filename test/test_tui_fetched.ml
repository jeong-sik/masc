(* The states a pane can be in about one fetched thing.

   The reason this is a type rather than two options: two options cannot say
   "asked, still waiting", so a pane before its first answer looked exactly
   like a pane with nothing in it. *)

open Alcotest
module F = Masc_tui_fetched

let equal = String.equal
let view t ~key = F.view_for ~equal t ~key

let started = function
  | F.Started (t, request) -> t, request
  | F.Already_loading -> fail "expected the request to start"
;;

let test_the_four_states_are_distinguishable () =
  let t = F.initial in
  check bool "never asked" true (view t ~key:"a" = F.Absent);
  let t, request = started (F.start ~equal t ~key:"a") in
  (* This is the state the option pair could not express. *)
  check bool "asked, waiting" true (view t ~key:"a" = F.Loading);
  let ready = F.complete ~equal t request (Ok "the answer") in
  check bool "answered" true (view ready ~key:"a" = F.Ready "the answer");
  let failed = F.complete ~equal t request (Error "it broke") in
  check bool "failed" true (view failed ~key:"a" = F.Failed "it broke")
;;

let test_a_pane_asks_once_per_key () =
  let t, _ = started (F.start ~equal F.initial ~key:"a") in
  (* The pane redraws per keystroke, so asking again for what is already in
     flight has to be a no-op rather than a second request. *)
  check bool "the same key while in flight does not ask again" true
    (F.start ~equal t ~key:"a" = F.Already_loading);
  match F.start ~equal t ~key:"b" with
  | F.Already_loading -> fail "a different key must ask"
  | F.Started (moved, _) ->
    check bool "and the old key is no longer what this pane is showing" true
      (view moved ~key:"a" = F.Absent);
    check bool "the new one is waiting" true (view moved ~key:"b" = F.Loading)
;;

let test_an_answer_for_a_key_left_behind_is_dropped () =
  let t, first = started (F.start ~equal F.initial ~key:"a") in
  let moved, _ = started (F.start ~equal t ~key:"b") in
  let settled = F.complete ~equal moved first (Ok "a's answer") in
  (* Rendering it would put one key's value under another key's name. *)
  check bool "the late answer does not land" true (view settled ~key:"b" = F.Loading);
  check bool "and it does not resurrect the key it belonged to" true
    (view settled ~key:"a" = F.Absent)
;;

let test_a_refresh_keeps_the_last_good_value_on_screen () =
  let t, request = started (F.start ~equal F.initial ~key:"a") in
  let ready = F.complete ~equal t request (Ok "first") in
  let refreshing, again = started (F.start ~equal ready ~key:"a") in
  (* Flipping back to Loading here empties the pane for a frame, and a scroll
     clamp that runs against the empty frame loses the reader's position. *)
  check bool "the old value keeps rendering" true
    (view refreshing ~key:"a" = F.Ready "first");
  let swapped = F.complete ~equal refreshing again (Ok "second") in
  check bool "and the new one replaces it when it lands" true
    (view swapped ~key:"a" = F.Ready "second")
;;

let test_clearing_forgets_it () =
  let t, request = started (F.start ~equal F.initial ~key:"a") in
  let ready = F.complete ~equal t request (Ok "answer") in
  check bool "cleared reads as never asked" true
    (view (F.clear ready) ~key:"a" = F.Absent)
;;

let () =
  run "tui_fetched"
    [ ( "states"
      , [ test_case "the four states are distinguishable" `Quick
            test_the_four_states_are_distinguishable
        ; test_case "a pane asks once per key" `Quick test_a_pane_asks_once_per_key
        ; test_case "an answer for a key left behind is dropped" `Quick
            test_an_answer_for_a_key_left_behind_is_dropped
        ; test_case "a refresh keeps the last good value on screen" `Quick
            test_a_refresh_keeps_the_last_good_value_on_screen
        ; test_case "clearing forgets it" `Quick test_clearing_forgets_it
        ] )
    ]
;;
