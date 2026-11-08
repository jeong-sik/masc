(** The decisions behind the failing-for cell (RFC-0511 D1): whether a keeper
    is failing and since when. The words and marks the cell draws are not
    asserted here. *)

module P = Masc_tui_keeper_pulse
module Cell = Masc_tui_keeper_axis_cell
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

let check_failing label expected actual =
  Alcotest.check failing_testable label expected actual

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

let () =
  Alcotest.run "tui_keeper_pulse"
    [ ( "failing"
      , [ Alcotest.test_case "failing is read from the health and the start" `Quick
            test_failing_is_read_from_health_and_start
        ; Alcotest.test_case "the failing cell" `Quick test_failing_cell_decisions
        ] )
    ]
;;
