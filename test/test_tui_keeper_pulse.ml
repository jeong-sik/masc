(** The decisions behind the failing-for cell and the turn-pulse cell
    (RFC-0511 D1): whether a keeper is failing and since when, what each hour
    of the 12-hour window holds, and what each half hour of the views' pulse
    column holds (RFC-0515 §2.4.3). The words and marks the cells draw are not
    asserted here; the checks on marks are about telling readings apart. *)

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

(* The views' half-hour pulse (RFC-0515 §2.4.3). *)

let half_hour_name = function
  | P.Half_hour_unknown -> "unknown"
  | P.Half_hour_quiet -> "quiet"
  | P.Half_hour_ok -> "ok"
  | P.Half_hour_failed -> "failed"
  | P.Half_hour_failed_and_ok -> "failed and ok"
;;

let half_hour_testable =
  Alcotest.testable (fun ppf half -> Format.pp_print_string ppf (half_hour_name half)) ( = )
;;

let check_half_hours label expected actual =
  Alcotest.(check (list half_hour_testable)) label expected actual

let half = Float.of_int Pulse.slot_seconds
let columns = 6

(* [now] is 20 minutes into its slot. *)
let now_slot = Float.of_int (Pulse.slot_start now)
let in_slot ?(minute = 5) back = now_slot -. (Float.of_int back *. half) +. Float.of_int (minute * 60)

(* The column oldest first. [held] names half hours back from the slot of
   [now] (0); every other half hour reads [fill]. *)
let column ~fill held =
  List.init columns (fun position ->
    match List.assoc_opt (columns - 1 - position) held with
    | Some half_hour -> half_hour
    | None -> fill)
;;

let half_hours pulse_option = P.half_hours ~now ~count:columns pulse_option

let test_no_pulse_is_unknown_in_every_half_hour () =
  check_half_hours "a pulse the server did not send"
    (column ~fill:P.Half_hour_unknown [])
    (half_hours None);
  check_half_hours "a pulse read against a clock that is not a number"
    (column ~fill:P.Half_hour_unknown [])
    (P.half_hours ~now:Float.nan ~count:columns (Some (pulse [ ago 60.0, Pulse.Turn_ok ])));
  check_half_hours "no column is no half hour" []
    (P.half_hours ~now ~count:0 (Some (pulse [ ago 60.0, Pulse.Turn_ok ])));
  check_half_hours "a negative column is no half hour" []
    (P.half_hours ~now ~count:(-3) None)
;;

let test_each_half_hour_reads_its_own_turns () =
  check_half_hours "ok, failed, rested as failed, both, rested and ok, none"
    (column ~fill:P.Half_hour_quiet
       [ 0, P.Half_hour_ok
       ; 1, P.Half_hour_failed
       ; 2, P.Half_hour_failed
       ; 3, P.Half_hour_failed_and_ok
       ; 4, P.Half_hour_failed_and_ok
       ])
    (half_hours
       (Some
          (pulse
             [ in_slot 0, Pulse.Turn_ok
             ; in_slot 1, Pulse.Turn_failed
             ; in_slot 2, Pulse.Turn_rested
             ; in_slot ~minute:2 3, Pulse.Turn_failed
             ; in_slot ~minute:20 3, Pulse.Turn_ok
             ; in_slot ~minute:2 4, Pulse.Turn_ok
             ; in_slot ~minute:20 4, Pulse.Turn_rested
             ])))
;;

let test_half_hour_boundaries () =
  let only at outcome = half_hours (Some (pulse [ at, outcome ])) in
  check_half_hours "the start of the slot of now is that slot"
    (column ~fill:P.Half_hour_quiet [ 0, P.Half_hour_ok ])
    (only now_slot Pulse.Turn_ok);
  check_half_hours "a second before it is the half hour before"
    (column ~fill:P.Half_hour_quiet [ 1, P.Half_hour_ok ])
    (only (now_slot -. 1.0) Pulse.Turn_ok);
  check_half_hours "the start of the oldest half hour of the column is in it"
    (column ~fill:P.Half_hour_quiet [ columns - 1, P.Half_hour_failed ])
    (only (now_slot -. (Float.of_int (columns - 1) *. half)) Pulse.Turn_failed);
  check_half_hours "a second before it is outside the column"
    (column ~fill:P.Half_hour_quiet [])
    (only (now_slot -. (Float.of_int (columns - 1) *. half) -. 1.0) Pulse.Turn_failed);
  check_half_hours "a turn stamped after the slot of now joins the slot of now"
    (column ~fill:P.Half_hour_quiet [ 0, P.Half_hour_failed_and_ok ])
    (half_hours (Some (pulse [ now +. (2.0 *. hour), Pulse.Turn_ok; in_slot 0, Pulse.Turn_failed ])))
;;

let test_half_hours_before_known_since_are_unknown () =
  let known_at back = now_slot -. (Float.of_int back *. half) in
  check_half_hours "a half hour that starts at known_since is held, the ones before are not"
    (column ~fill:P.Half_hour_quiet
       [ 3, P.Half_hour_unknown; 4, P.Half_hour_ok; 5, P.Half_hour_unknown ])
    (half_hours (Some (pulse ~known_since:(known_at 2) [ in_slot 4, Pulse.Turn_ok ])));
  check_half_hours "a second after its start, that half hour is not held either"
    (column ~fill:P.Half_hour_quiet
       [ 2, P.Half_hour_unknown; 3, P.Half_hour_unknown; 4, P.Half_hour_unknown
       ; 5, P.Half_hour_unknown ])
    (half_hours (Some (pulse ~known_since:(known_at 2 +. 1.0) [])));
  check_half_hours "a pulse that knows nothing before now holds no empty half hour"
    (column ~fill:P.Half_hour_unknown [ 0, P.Half_hour_failed ])
    (half_hours (Some (pulse ~known_since:now [ now, Pulse.Turn_failed ])))
;;

let test_the_half_hours_draw_different_marks () =
  let readings =
    [ P.Half_hour_unknown; P.Half_hour_quiet; P.Half_hour_ok; P.Half_hour_failed
    ; P.Half_hour_failed_and_ok ]
  in
  let marks = List.map P.half_hour_mark readings in
  Alcotest.(check int) "five readings, five marks" (List.length readings)
    (List.length (List.sort_uniq String.compare marks))
;;

let test_failed_counts_preserve_unknown_readings () =
  let check label expected actual = Alcotest.(check bool) label true (expected = actual) in
  check "unobserved day is unknown, not zero" P.Count_unknown
    (P.failure_count (P.half_hours ~now ~count:48 None));
  check "known quiet and ok are exactly zero" (P.Exact 0)
    (P.failure_count [P.Half_hour_quiet; P.Half_hour_ok]);
  check "mixed failed outcomes each count once" (P.Exact 2)
    (P.failure_count [P.Half_hour_failed; P.Half_hour_failed_and_ok; P.Half_hour_ok]);
  check "partial observations give a positive lower bound" (P.At_least 1)
    (P.failure_count [P.Half_hour_failed; P.Half_hour_unknown]);
  check "no positive lower bound stays unknown" P.Count_unknown
    (P.failure_count [P.Half_hour_quiet; P.Half_hour_unknown]);
  check "a missing fleet reading can raise the peak" (P.At_least 2)
    (P.peak_failure_count [P.Exact 2; P.Count_unknown]);
  check "fully unknown fleet peak is unknown" P.Count_unknown
    (P.peak_failure_count [P.Count_unknown]);
  check "fully observed fleet peak is exact" (P.Exact 2)
    (P.peak_failure_count [P.Exact 0; P.Exact 2]);
  check "empty fleet is a known zero" (P.Exact 0) (P.peak_failure_count [])

let () =
  Alcotest.run "tui_keeper_pulse"
    [ ( "failing"
      , [ Alcotest.test_case "failed counts preserve unknown readings" `Quick test_failed_counts_preserve_unknown_readings
        ; Alcotest.test_case "failing is read from the health and the start" `Quick
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
    ; ( "half hours"
      , [ Alcotest.test_case "no pulse is unknown in every half hour" `Quick
            test_no_pulse_is_unknown_in_every_half_hour
        ; Alcotest.test_case "each half hour reads its own turns" `Quick
            test_each_half_hour_reads_its_own_turns
        ; Alcotest.test_case "half hour boundaries" `Quick test_half_hour_boundaries
        ; Alcotest.test_case "half hours before known_since are unknown" `Quick
            test_half_hours_before_known_since_are_unknown
        ; Alcotest.test_case "the half hours draw different marks" `Quick
            test_the_half_hours_draw_different_marks
        ] )
    ]
;;
