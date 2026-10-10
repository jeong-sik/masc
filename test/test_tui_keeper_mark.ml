(** Four health readings, four marks.

    Exhaustiveness is the compiler's job; what it cannot check is that two
    readings did not quietly settle on the same character, or that a keeper
    that is not turning, or whose turns are failing, drew what a working
    keeper draws. *)

module Mark = Masc_tui_keeper_mark
module Reading = Masc.Tui_decode

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let readings =
  [ "running", Reading.Health_running
  ; "idle", Reading.Health_idle
  ; "failing", Reading.Health_failing
  ; "offline", Reading.Health_offline
  ]

let test_the_column_legend_explains_every_letter_the_cell_draws () =
  let contains haystack needle =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
  let modes =
    [ Reading.Activation_manual; Reading.Activation_on_demand; Reading.Activation_autonomous ]
  in
  let mode_letters = List.map Mark.activation_letter modes in
  check_int "each activation mode draws its own letter" (List.length modes)
    (List.length (List.sort_uniq String.compare mode_letters));
  let sandboxes = List.filter_map Mark.sandbox_of_profile [ "docker"; "microvm"; "local" ] in
  check_int "the three declared profiles are sandboxes" 3 (List.length sandboxes);
  check_bool "a profile this build does not know is not one of them" true
    (Option.is_none (Mark.sandbox_of_profile "mock"));
  let sandbox_letters = List.map Mark.sandbox_letter sandboxes in
  check_int "each sandbox draws its own letter" 3
    (List.length (List.sort_uniq String.compare sandbox_letters));
  let keys = String.concat " " (List.map fst Mark.column_legend) in
  List.iter
    (fun letter -> check_bool ("the legend shows letter " ^ letter) true (contains keys letter))
    (mode_letters @ sandbox_letters);
  List.iter
    (fun header -> check_bool ("the legend names " ^ header) true (contains keys header))
    [ "HEALTH"; "LIFECYCLE"; "TURN"; "Mode"; "S " ]

(* An open turn draws the turn's mark, and that mark is the working mark. A
   failing keeper keeps a turn open while its keepalive retries, so this is
   where it would draw exactly what a working keeper draws; its health word
   is what keeps the row findable under a header that counts it failing. *)
let open_turn = Mark.open_turn

let test_a_failing_keepers_open_turn_keeps_its_health_word () =
  check_bool "a failing keeper's turn keeps the failing word" true
    (open_turn (Some Reading.Health_failing) = Mark.Worked_while_failing);
  check_bool "and does not draw what a working keeper's turn draws" true
    (open_turn (Some Reading.Health_failing)
     <> open_turn (Some Reading.Health_running))

let test_an_offline_keepers_open_turn_is_left_open () =
  check_bool "nothing works the turn of an offline keeper" true
    (open_turn (Some Reading.Health_offline) = Mark.Left_open)

let test_a_working_keepers_open_turn_is_worked () =
  List.iter
    (fun (name, reading) ->
      check_bool (name ^ " draws the working mark") true
        (open_turn reading = Mark.Worked))
    [ "running", Some Reading.Health_running
    ; "idle", Some Reading.Health_idle
    ; "unread", None
    ]

(* The TURN cell. code-reviewer failed twice, the server restarted, and the
   keeper's failure streak came back with it, so its row read failing while a
   fresh turn ran. The cell drew the age of the last recorded turn -- the
   failure, 7m45s -- beside the moving mark, and the operator could not tell
   the past failure from the work in progress. The open turn is what the
   keeper is doing now; its start is where the cell counts from. *)
let running ~started_at_unix =
  Reading.Keeper_turn_running
    { lane = Reading.Turn_lane_autonomous
    ; started_at_unix
    ; interrupt_token = "7a8b9c0d-1e2f-4a3b-9c4d-5e6f7a8b9c0d"
    ; turn_ref = None
    ; preview = None
    }

let failed_at = 1_790_000_000.
let restarted_turn_started_at = failed_at +. 433.

let test_an_open_turn_after_a_failure_counts_from_the_open_turn () =
  check_bool "the open turn's start, not the failure before it" true
    (Mark.turn_clock
       ~turn:(Some (running ~started_at_unix:restarted_turn_started_at))
       ~last_turn_at:(Some failed_at)
     = Mark.Open_turn_started restarted_turn_started_at);
  check_bool "an open turn is its own clock even when none was recorded" true
    (Mark.turn_clock
       ~turn:(Some (running ~started_at_unix:restarted_turn_started_at))
       ~last_turn_at:None
     = Mark.Open_turn_started restarted_turn_started_at)

let test_with_no_open_turn_the_last_recorded_turn_is_the_clock () =
  List.iter
    (fun (name, turn) ->
      check_bool (name ^ " counts from the last recorded turn") true
        (Mark.turn_clock ~turn ~last_turn_at:(Some failed_at)
         = Mark.Last_turn_recorded failed_at);
      check_bool (name ^ " with nothing recorded has no clock") true
        (Mark.turn_clock ~turn ~last_turn_at:None = Mark.No_turn_recorded))
    [ "an idle turn", Some Reading.Keeper_turn_idle
    ; "an unavailable turn reading", Some (Reading.Keeper_turn_unavailable "owner lookup failed")
    ; "a keeper the turns poll does not list", None
    ]

let () =
  Alcotest.run "tui_keeper_mark"
    [ ( "marks"
      , [ Alcotest.test_case "the column legend explains every letter" `Quick
            test_the_column_legend_explains_every_letter_the_cell_draws
        ] )
    ; ( "open turn"
      , [ Alcotest.test_case "a failing keeper's open turn keeps its health word"
            `Quick test_a_failing_keepers_open_turn_keeps_its_health_word
        ; Alcotest.test_case "an offline keeper's open turn is left open" `Quick
            test_an_offline_keepers_open_turn_is_left_open
        ; Alcotest.test_case "a working keeper's open turn is worked" `Quick
            test_a_working_keepers_open_turn_is_worked
        ] )
    ; ( "turn clock"
      , [ Alcotest.test_case "an open turn after a failure counts from the open turn"
            `Quick test_an_open_turn_after_a_failure_counts_from_the_open_turn
        ; Alcotest.test_case "with no open turn the last recorded turn is the clock"
            `Quick test_with_no_open_turn_the_last_recorded_turn_is_the_clock
        ] )
    ]
