(** Four health readings, four marks.

    Exhaustiveness is the compiler's job; what it cannot check is that two
    readings did not quietly settle on the same character, or that a keeper
    that is not turning, or whose turns are failing, drew what a working
    keeper draws. *)

module Mark = Masc_tui_keeper_mark
module Reading = Masc.Tui_decode

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)

let readings =
  [ "running", Reading.Health_running
  ; "idle", Reading.Health_idle
  ; "failing", Reading.Health_failing
  ; "offline", Reading.Health_offline
  ]

let test_every_reading_gets_its_own_mark () =
  let marks = List.map (fun (_, r) -> Mark.glyph ~paused:false (Some r)) readings in
  let distinct = List.sort_uniq String.compare marks in
  check_int "each reading draws its own mark" (List.length readings) (List.length distinct)

(* A failing keeper is still turning, so the test below does not cover it,
   and it is the keeper that most needs to look unlike a working one: before
   it had a reading of its own, the chat header drew "healthy" beside its
   "failing" phase. *)
let test_a_failing_keeper_does_not_draw_the_working_mark () =
  let working = Mark.glyph ~paused:false (Some Reading.Health_running) in
  check_bool "failing reads differently from a working keeper" true
    (Mark.glyph ~paused:false (Some Reading.Health_failing) <> working)

let test_a_keeper_that_is_not_turning_does_not_draw_the_working_mark () =
  let working = Mark.glyph ~paused:false (Some Reading.Health_running) in
  List.iter
    (fun name_reading ->
      let name, reading = name_reading in
      check_bool (name ^ " reads differently from a working keeper") true
        (Mark.glyph ~paused:false (Some reading) <> working))
    [ "idle", Reading.Health_idle; "offline", Reading.Health_offline ]

let test_pause_outranks_the_reading () =
  let paused_marks =
    List.map (fun (_, r) -> Mark.glyph ~paused:true (Some r)) readings
    |> List.sort_uniq String.compare
  in
  check_int "a paused keeper draws one mark whatever its health" 1
    (List.length paused_marks)

let test_an_unread_roster_is_not_a_health () =
  let unread = Mark.glyph ~paused:false None in
  List.iter
    (fun (name, reading) ->
      check_bool ("unread differs from " ^ name) true
        (Mark.glyph ~paused:false (Some reading) <> unread))
    readings;
  check_bool "and an unread roster is not the paused mark" true
    (unread <> Mark.glyph ~paused:true (Some Reading.Health_running))

let test_every_mark_is_one_column_wide () =
  List.iter
    (fun (mark, word) ->
      check_int (word ^ " mark is one cell")
        1
        (Masc_tui_message_layout.display_width mark))
    Mark.legend

let test_the_legend_names_every_mark_once () =
  let marks = List.map fst Mark.legend in
  check_int "no mark is listed twice" (List.length marks)
    (List.length (List.sort_uniq String.compare marks));
  let words = List.map snd Mark.legend in
  check_bool "the legend covers failing" true (List.mem "failing" words);
  check_bool "the legend covers offline" true (List.mem "offline" words);
  check_bool "the legend covers unread" true (List.mem "unread" words);
  check_string "a working keeper heads the legend" "healthy" (List.hd words)

(* The Mode S cell draws letters, and the sheet is where a reader learns them.
   Both come from this module, so a letter the cell draws is a letter the
   legend explains. *)
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

let test_a_working_keepers_open_turn_shows_how_long () =
  List.iter
    (fun (name, reading) ->
      check_bool (name ^ " draws the turn's elapsed time") true
        (open_turn reading = Mark.Worked))
    [ "running", Some Reading.Health_running
    ; "idle", Some Reading.Health_idle
    ; "unread", None
    ]

let () =
  Alcotest.run "tui_keeper_mark"
    [ ( "marks"
      , [ Alcotest.test_case "every reading gets its own mark" `Quick
            test_every_reading_gets_its_own_mark
        ; Alcotest.test_case "a keeper that is not turning does not draw the working mark"
            `Quick test_a_keeper_that_is_not_turning_does_not_draw_the_working_mark
        ; Alcotest.test_case "a failing keeper does not draw the working mark" `Quick
            test_a_failing_keeper_does_not_draw_the_working_mark
        ; Alcotest.test_case "pause outranks the reading" `Quick
            test_pause_outranks_the_reading
        ; Alcotest.test_case "an unread roster is not a health" `Quick
            test_an_unread_roster_is_not_a_health
        ; Alcotest.test_case "every mark is one column wide" `Quick
            test_every_mark_is_one_column_wide
        ; Alcotest.test_case "the legend names every mark once" `Quick
            test_the_legend_names_every_mark_once
        ; Alcotest.test_case "the column legend explains every letter" `Quick
            test_the_column_legend_explains_every_letter_the_cell_draws
        ] )
    ; ( "open turn"
      , [ Alcotest.test_case "a failing keeper's open turn keeps its health word"
            `Quick test_a_failing_keepers_open_turn_keeps_its_health_word
        ; Alcotest.test_case "an offline keeper's open turn is left open" `Quick
            test_an_offline_keepers_open_turn_is_left_open
        ; Alcotest.test_case "a working keeper's open turn shows how long" `Quick
            test_a_working_keepers_open_turn_shows_how_long
        ] )
    ]
