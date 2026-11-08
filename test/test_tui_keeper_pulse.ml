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

(* [now] is 20 minutes into its clock hour. *)
let now_hour = Float.of_int (int_of_float (Float.floor (now /. hour)) * 3600)
let in_hour ?(minute = 5) back = now_hour -. (Float.of_int back *. hour) +. Float.of_int (minute * 60)

(* The server's slots for [turns], newest first. *)
let pulse ?(known_since = now -. (24.0 *. hour)) turns : Pulse.pulse =
  let add slots (at, outcome) =
    let starts_at = Pulse.slot_start at in
    let tally =
      Option.value (List.assoc_opt starts_at slots)
        ~default:{ Pulse.ok = 0; rested = 0; failed = 0 }
    in
    let tally =
      match outcome with
      | Pulse.Turn_ok -> { tally with Pulse.ok = tally.Pulse.ok + 1 }
      | Pulse.Turn_rested -> { tally with Pulse.rested = tally.Pulse.rested + 1 }
      | Pulse.Turn_failed -> { tally with Pulse.failed = tally.Pulse.failed + 1 }
    in
    (starts_at, tally) :: List.remove_assoc starts_at slots
  in
  let slots =
    List.fold_left add [] turns
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map (fun (starts_at, tally) -> { Pulse.starts_at; tally })
  in
  { Pulse.known_since; slots }
;;

(* The window oldest hour first. [held] names slots by clock hours back from
   the hour of [now] (0); every other hour reads [fill]. *)
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
  check_slots "a pulse the server did not send"
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
    (Option.is_none (P.pulse_cell ~now (Some (pulse [ in_hour 13, Pulse.Turn_failed ]))))
;;

let test_each_turn_lands_in_its_clock_hour () =
  check_slots "the hour of now at the end, five hours back in the seventh slot"
    (window ~fill:P.Slot_quiet [ 0, failed; 5, ok ])
    (P.slots ~now (Some (pulse [ in_hour 0, Pulse.Turn_failed; in_hour 5, Pulse.Turn_ok ])))
;;

let test_hour_boundaries () =
  let only at = P.slots ~now (Some (pulse [ at, Pulse.Turn_ok ])) in
  check_slots "the start of the hour of now is that hour"
    (window ~fill:P.Slot_quiet [ 0, ok ])
    (only now_hour);
  check_slots "a second before it is the hour before"
    (window ~fill:P.Slot_quiet [ 1, ok ])
    (only (now_hour -. 1.0));
  check_slots "the start of the eleventh hour back is the oldest hour"
    (window ~fill:P.Slot_quiet [ Mark.pulse_hours - 1, ok ])
    (only (now_hour -. (11.0 *. hour)));
  check_slots "a second before it is outside the window"
    (window ~fill:P.Slot_quiet [])
    (only (now_hour -. (11.0 *. hour) -. 1.0));
  check_slots "a turn stamped after the hour of now belongs to it"
    (window ~fill:P.Slot_quiet [ 0, ok ])
    (only (now +. (2.0 *. hour)))
;;

let test_the_worst_turn_of_an_hour_is_the_hour () =
  let newest turns = List.nth (P.slots ~now (Some (pulse turns))) (Mark.pulse_hours - 1) in
  Alcotest.check slot_testable "ok alone" ok (newest [ in_hour 0, Pulse.Turn_ok ]);
  Alcotest.check slot_testable "rested in the other half hour is over ok" rested
    (newest [ in_hour ~minute:5 0, Pulse.Turn_ok; in_hour ~minute:40 0, Pulse.Turn_rested ]);
  Alcotest.check slot_testable "failed over rested and ok" failed
    (newest
       [ in_hour ~minute:5 0, Pulse.Turn_rested
       ; in_hour ~minute:6 0, Pulse.Turn_ok
       ; in_hour ~minute:45 0, Pulse.Turn_failed
       ])
;;

let test_hours_before_known_since_are_unknown () =
  let known_since = now_hour -. (3.5 *. hour) in
  let unknown_from_hour_4 = List.init 8 (fun i -> 4 + i, P.Slot_unknown) in
  check_slots "an empty hour that starts before known_since is unknown, a turn still shows"
    (window ~fill:P.Slot_quiet ((6, failed) :: (0, ok) :: List.remove_assoc 6 unknown_from_hour_4))
    (P.slots ~now
       (Some (pulse ~known_since [ in_hour 0, Pulse.Turn_ok; in_hour 6, Pulse.Turn_failed ])));
  check_slots "a pulse that knows nothing before now knows no empty hour"
    (window ~fill:P.Slot_unknown [ 0, ok ])
    (P.slots ~now (Some (pulse ~known_since:now [ now, Pulse.Turn_ok ])));
  check_slots "a pulse that knows the whole day has no unknown hour"
    (window ~fill:P.Slot_quiet [ 11, ok ])
    (P.slots ~now (Some (pulse [ in_hour 11, Pulse.Turn_ok ])))
;;

let test_the_cell_tone_follows_failures () =
  let tone pulse_option = (cell_of "pulse" (P.pulse_cell ~now pulse_option)).Cell.tone in
  check_bool "a failed turn asks for attention" true
    (tone (Some (pulse [ in_hour 0, Pulse.Turn_failed ])) = Cell.Attention);
  check_bool "ok and rested turns stay quiet" true
    (tone (Some (pulse [ in_hour 0, Pulse.Turn_ok; in_hour 1, Pulse.Turn_rested ])) = Cell.Quiet);
  check_bool "hours the server does not hold stay quiet" true (tone None = Cell.Quiet);
  check_bool "a failure older than the window is not in the window" true
    (tone (Some (pulse [ in_hour 0, Pulse.Turn_ok; in_hour 13, Pulse.Turn_failed ])) = Cell.Quiet)
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
        ; Alcotest.test_case "each turn lands in its clock hour" `Quick
            test_each_turn_lands_in_its_clock_hour
        ; Alcotest.test_case "hour boundaries" `Quick test_hour_boundaries
        ; Alcotest.test_case "the worst turn is the hour" `Quick
            test_the_worst_turn_of_an_hour_is_the_hour
        ; Alcotest.test_case "hours before known_since are unknown" `Quick
            test_hours_before_known_since_are_unknown
        ; Alcotest.test_case "the cell tone follows failures" `Quick
            test_the_cell_tone_follows_failures
        ; Alcotest.test_case "the readings draw different marks" `Quick
            test_the_readings_draw_different_marks
        ] )
    ]
;;
