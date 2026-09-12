open Alcotest
module Types = Masc_tui_types

(* What the keeper detail tabs say while a read is in flight.

   The seconds are the point: against a live server the Sandbox tab's status
   took somewhere between five and sixteen seconds, and a bare "(loading...)"
   held through that window is read as a stall -- the operator starts pressing
   keys. A read that answers at once must not flash a number, which is what the
   floor is for. *)

let cut = "\xe2\x80\xa6"

let fresh () =
  Types.create_state ~workspace:"me" ~port:8935 ~refresh_interval:2.0 ()

let test_a_quick_read_says_no_number () =
  check string "nothing measured, nothing said" ("(loading" ^ cut ^ ")")
    (Types.loading_notice "loading");
  check string "under the floor, still nothing" ("(loading" ^ cut ^ ")")
    (Types.loading_notice ~elapsed_s:1 "loading")

let test_a_slow_read_says_how_long () =
  check string "at the floor" ("(loading" ^ cut ^ " 2s)")
    (Types.loading_notice ~elapsed_s:Types.pending_seconds_floor "loading");
  check string "and past it" ("(loading" ^ cut ^ " 16s)")
    (Types.loading_notice ~elapsed_s:16 "loading");
  check string "whatever the read is called"
    ("(loading actual container logs" ^ cut ^ " 7s)")
    (Types.loading_notice ~elapsed_s:7 "loading actual container logs")

let test_the_elapsed_needs_a_start () =
  let state = fresh () in
  check (option int) "a screen that has asked for nothing measures nothing" None
    (Types.detail_read_elapsed ~now:100. state);
  state.detail_read_started_at <- Some 90.;
  check (option int) "ten seconds since the read began" (Some 10)
    (Types.detail_read_elapsed ~now:100. state);
  (* A clock that moved backwards must not count up from the future. *)
  check (option int) "a backwards clock counts zero" (Some 0)
    (Types.detail_read_elapsed ~now:80. state)

let () =
  run "tui loading notice"
    [ ( "a read in flight"
      , [ test_case "a quick read says no number" `Quick
            test_a_quick_read_says_no_number
        ; test_case "a slow read says how long" `Quick
            test_a_slow_read_says_how_long
        ; test_case "the elapsed needs a start" `Quick
            test_the_elapsed_needs_a_start
        ] )
    ]
