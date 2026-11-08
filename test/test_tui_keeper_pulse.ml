(** The decisions behind the failing-for cell and the turn-pulse cell
    (RFC-0511 D1): whether a keeper is failing and since when, and what each
    hour of the 12-hour window holds. The words and marks the cells draw are
    not asserted here; the two checks on marks are about telling readings apart. *)

module P = Masc_tui_keeper_pulse
module Mark = Masc_tui_keeper_mark
module Cell = Masc_tui_keeper_axis_cell
module Pulse = Masc.Keeper_turn_pulse
module Reading = Masc.Tui_decode

let now = 1_794_000_000.0
let hour = 3600.0
let ago seconds = now -. seconds
let check_bool = Alcotest.(check bool)

let failing_name = function
  | P.Not_failing -> "not failing"
  | P.Failing_since at -> Printf.sprintf "failing since %.0f" at
  | P.Failing_unrecorded -> "failing, start not recorded"
;;

let failing_testable =
  Alcotest.testable (fun ppf failing -> Format.pp_print_string ppf (failing_name failing)) ( = )
;;

let slot_name = function
  | P.Slot_unknown -> "unknown"
  | P.Slot_quiet -> "quiet"
  | P.Slot_turn Pulse.Turn_ok -> "ok"
  | P.Slot_turn Pulse.Turn_rested -> "rested"
  | P.Slot_turn Pulse.Turn_failed -> "failed"
;;

let slot_testable =
  Alcotest.testable (fun ppf slot -> Format.pp_print_string ppf (slot_name slot)) ( = )
;;

let check_failing label expected actual =
  Alcotest.check failing_testable label expected actual

let check_slots label expected actual =
  Alcotest.(check (list slot_testable)) label expected actual

let ok = P.Slot_turn Pulse.Turn_ok
let rested = P.Slot_turn Pulse.Turn_rested
let failed = P.Slot_turn Pulse.Turn_failed

let pulse ?(truncated = false) samples : Pulse.pulse =
  { Pulse.samples = List.map (fun (at, outcome) -> { Pulse.at; outcome }) samples
  ; truncated
  }
;;

(* The window oldest hour first. [held] names slots by hours back from [now]
   (0 is the hour just ended); every other hour reads [fill]. *)
let window ~fill held =
  List.init Mark.pulse_hours (fun position ->
    match List.assoc_opt (Mark.pulse_hours - 1 - position) held with
    | Some slot -> slot
    | None -> fill)
;;

let cell_of label = function
  | Some cell -> cell
  | None -> Alcotest.failf "%s: expected a cell" label
;;

let test_failing_is_read_from_health_and_start () =
  let start = Some (ago 600.0) in
  check_failing "failing with a recorded start"
    (P.Failing_since (ago 600.0))
    (P.failing_of_health ~health:Reading.Health_failing ~failing_since:start);
  check_failing "failing with no recorded start" P.Failing_unrecorded
    (P.failing_of_health ~health:Reading.Health_failing ~failing_since:None);
  List.iter
    (fun (name, health) ->
      List.iter
        (fun failing_since ->
          check_failing (name ^ " is not failing, whatever the start says") P.Not_failing
            (P.failing_of_health ~health ~failing_since))
        [ None; start ])
    [ "running", Reading.Health_running
    ; "idle", Reading.Health_idle
    ; "offline", Reading.Health_offline
    ]
;;

let test_failing_cell_decisions () =
  check_bool "a keeper that is not failing draws no cell" true
    (Option.is_none (P.failing_cell ~now P.Not_failing));
  let cell failing = cell_of (failing_name failing) (P.failing_cell ~now failing) in
  List.iter
    (fun failing ->
      check_bool (failing_name failing ^ " is a failure") true
        ((cell failing).Cell.tone = Cell.Failure))
    [ P.Failing_since (ago 600.0); P.Failing_unrecorded ];
  let unrecorded = (cell P.Failing_unrecorded).Cell.text in
  check_bool "a start not recorded does not read like a start of now" true
    (unrecorded <> (cell (P.Failing_since now)).Cell.text);
  check_bool "a start long ago reads differently from a start a moment ago" true
    ((cell (P.Failing_since (ago (3.0 *. hour)))).Cell.text
     <> (cell (P.Failing_since (ago 5.0))).Cell.text);
  List.iter
    (fun (label, since) ->
      check_bool (label ^ " reads as a start not recorded") true
        ((cell (P.Failing_since since)).Cell.text = unrecorded))
    [ "a start ahead of now", now +. 60.0
    ; "a start too far back to be a span", -1e18
    ; "a start that is not a number", Float.nan
    ]
;;

let test_no_pulse_is_unknown_in_every_hour () =
  check_slots "a pulse the server did not seed"
    (window ~fill:P.Slot_unknown [])
    (P.slots ~now None);
  check_slots "a pulse read against a clock that is not a number"
    (window ~fill:P.Slot_unknown [])
    (P.slots ~now:Float.nan (Some (pulse [ ago 60.0, Pulse.Turn_ok ])));
  check_bool "unknown hours draw a cell" true (Option.is_some (P.pulse_cell ~now None))
;;

let test_a_complete_window_without_turns_is_quiet_and_draws_nothing () =
  check_slots "twelve quiet hours"
    (window ~fill:P.Slot_quiet [])
    (P.slots ~now (Some (pulse [])));
  check_bool "nothing to draw" true (Option.is_none (P.pulse_cell ~now (Some (pulse []))));
  check_bool "a turn older than the window leaves the window quiet" true
    (Option.is_none
       (P.pulse_cell ~now (Some (pulse [ ago (13.0 *. hour), Pulse.Turn_failed ]))))
;;

let test_each_turn_lands_in_the_hour_it_ended () =
  check_slots "newest hour at the end, a turn five hours back in the seventh slot"
    (window ~fill:P.Slot_quiet [ 0, failed; 5, ok ])
    (P.slots ~now
       (Some (pulse [ ago 1800.0, Pulse.Turn_failed; ago ((5.0 *. hour) +. 1800.0), Pulse.Turn_ok ])));
  check_slots "samples may come in either order"
    (P.slots ~now (Some (pulse [ ago 1800.0, Pulse.Turn_failed; ago (5.5 *. hour), Pulse.Turn_ok ])))
    (P.slots ~now (Some (pulse [ ago (5.5 *. hour), Pulse.Turn_ok; ago 1800.0, Pulse.Turn_failed ])))
;;

let test_hour_boundaries () =
  let only at = P.slots ~now (Some (pulse [ at, Pulse.Turn_ok ])) in
  check_slots "a turn now belongs to the newest hour" (window ~fill:P.Slot_quiet [ 0, ok ]) (only now);
  check_slots "just under an hour back is still the newest hour"
    (window ~fill:P.Slot_quiet [ 0, ok ])
    (only (ago (hour -. 1.0)));
  check_slots "an hour back starts the next hour"
    (window ~fill:P.Slot_quiet [ 1, ok ])
    (only (ago hour));
  check_slots "just under twelve hours back is the oldest hour"
    (window ~fill:P.Slot_quiet [ Mark.pulse_hours - 1, ok ])
    (only (ago ((12.0 *. hour) -. 1.0)));
  check_slots "twelve hours back is outside the window"
    (window ~fill:P.Slot_quiet [])
    (only (ago (12.0 *. hour)));
  check_slots "a turn stamped after now belongs to the newest hour"
    (window ~fill:P.Slot_quiet [ 0, ok ])
    (only (now +. 120.0))
;;

let test_the_worst_turn_of_an_hour_is_the_hour () =
  let hour_of outcomes =
    P.slots ~now
      (Some (pulse (List.mapi (fun i outcome -> ago (60.0 *. Float.of_int (i + 1)), outcome) outcomes)))
  in
  let newest slots = List.nth slots (Mark.pulse_hours - 1) in
  Alcotest.check slot_testable "ok alone" ok (newest (hour_of [ Pulse.Turn_ok ]));
  Alcotest.check slot_testable "rested over ok" rested
    (newest (hour_of [ Pulse.Turn_ok; Pulse.Turn_rested; Pulse.Turn_ok ]));
  Alcotest.check slot_testable "failed over rested and ok" failed
    (newest (hour_of [ Pulse.Turn_rested; Pulse.Turn_ok; Pulse.Turn_failed; Pulse.Turn_ok ]));
  Alcotest.check slot_testable "failed first" failed
    (newest (hour_of [ Pulse.Turn_failed; Pulse.Turn_rested ]))
;;

let test_a_cut_pulse_does_not_know_the_hours_before_its_oldest_turn () =
  let samples = [ ago 600.0, Pulse.Turn_ok; ago ((3.0 *. hour) +. 1800.0), Pulse.Turn_failed ] in
  let unknown_before_hour_3 = List.init 8 (fun i -> 4 + i, P.Slot_unknown) in
  check_slots "hours older than the oldest held turn are unknown, newer empty hours quiet"
    (window ~fill:P.Slot_quiet ((3, failed) :: (0, ok) :: unknown_before_hour_3))
    (P.slots ~now (Some (pulse ~truncated:true samples)));
  check_slots "the same turns without the cut mark leave those hours quiet"
    (window ~fill:P.Slot_quiet [ 3, failed; 0, ok ])
    (P.slots ~now (Some (pulse samples)));
  check_slots "a cut pulse that holds a turn older than the window knows every hour"
    (window ~fill:P.Slot_quiet [ 0, ok ])
    (P.slots ~now
       (Some (pulse ~truncated:true [ ago 600.0, Pulse.Turn_ok; ago (13.0 *. hour), Pulse.Turn_ok ])));
  check_slots "a cut pulse that holds nothing knows nothing"
    (window ~fill:P.Slot_unknown [])
    (P.slots ~now (Some (pulse ~truncated:true [])));
  check_slots "a cut pulse whose oldest turn is in the oldest hour knows every hour"
    (window ~fill:P.Slot_quiet [ Mark.pulse_hours - 1, ok ])
    (P.slots ~now (Some (pulse ~truncated:true [ ago ((11.0 *. hour) +. 1800.0), Pulse.Turn_ok ])))
;;

let test_a_turn_with_no_time_is_left_out () =
  check_slots "a turn whose time is not a number places nowhere"
    (P.slots ~now (Some (pulse [ ago 600.0, Pulse.Turn_ok ])))
    (P.slots ~now (Some (pulse [ ago 600.0, Pulse.Turn_ok; Float.nan, Pulse.Turn_failed ])));
  check_slots "a turn whose time is infinite places nowhere"
    (P.slots ~now (Some (pulse [ ago 600.0, Pulse.Turn_ok ])))
    (P.slots ~now
       (Some (pulse [ ago 600.0, Pulse.Turn_ok; Float.infinity, Pulse.Turn_failed; Float.neg_infinity, Pulse.Turn_failed ])))
;;

let test_the_cell_tone_follows_failures () =
  let tone pulse_option = (cell_of "pulse" (P.pulse_cell ~now pulse_option)).Cell.tone in
  check_bool "a failed turn asks for attention" true
    (tone (Some (pulse [ ago 600.0, Pulse.Turn_failed ])) = Cell.Attention);
  check_bool "ok and rested turns stay quiet" true
    (tone (Some (pulse [ ago 600.0, Pulse.Turn_ok; ago 4000.0, Pulse.Turn_rested ])) = Cell.Quiet);
  check_bool "hours the server does not hold stay quiet" true (tone None = Cell.Quiet);
  check_bool "a failure older than the window is not in the window" true
    (tone (Some (pulse [ ago 600.0, Pulse.Turn_ok; ago (13.0 *. hour), Pulse.Turn_failed ]))
     = Cell.Quiet)
;;

let test_the_readings_draw_different_marks () =
  let readings = [ P.Slot_unknown; P.Slot_quiet; ok; rested; failed ] in
  let marks = List.map P.slot_mark readings in
  Alcotest.(check int) "five readings, five marks" (List.length readings)
    (List.length (List.sort_uniq String.compare marks))
;;

let () =
  Alcotest.run "tui_keeper_pulse"
    [ ( "failing"
      , [ Alcotest.test_case "failing is read from the health and the start" `Quick
            test_failing_is_read_from_health_and_start
        ; Alcotest.test_case "the failing cell" `Quick test_failing_cell_decisions
        ] )
    ; ( "pulse"
      , [ Alcotest.test_case "no pulse is unknown in every hour" `Quick
            test_no_pulse_is_unknown_in_every_hour
        ; Alcotest.test_case "a complete empty window draws nothing" `Quick
            test_a_complete_window_without_turns_is_quiet_and_draws_nothing
        ; Alcotest.test_case "each turn lands in the hour it ended" `Quick
            test_each_turn_lands_in_the_hour_it_ended
        ; Alcotest.test_case "hour boundaries" `Quick test_hour_boundaries
        ; Alcotest.test_case "the worst turn is the hour" `Quick
            test_the_worst_turn_of_an_hour_is_the_hour
        ; Alcotest.test_case "a cut pulse does not know the older hours" `Quick
            test_a_cut_pulse_does_not_know_the_hours_before_its_oldest_turn
        ; Alcotest.test_case "a turn with no time is left out" `Quick
            test_a_turn_with_no_time_is_left_out
        ; Alcotest.test_case "the cell tone follows failures" `Quick
            test_the_cell_tone_follows_failures
        ; Alcotest.test_case "the readings draw different marks" `Quick
            test_the_readings_draw_different_marks
        ] )
    ]
;;
