(** Six health readings, six marks.

    The mark used to come from a string match on the health label with a
    catch-all: [offline] got its own character and everything else fell to the
    healthy dot. Stale, degraded, and zombie -- three keepers that are not
    working -- drew what a working keeper draws, and a renamed label would
    have joined them without a word from the compiler.

    These tests pin that the readings stay distinguishable. Exhaustiveness is
    the compiler's job; what it cannot check is that two readings did not
    quietly settle on the same character. *)

module Mark = Masc_tui_keeper_mark
module Reading = Masc.Tui_decode

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)

let readings =
  [ "running", Reading.Health_running
  ; "idle", Reading.Health_idle
  ; "offline", Reading.Health_offline
  ; "stale", Reading.Health_stale
  ; "degraded", Reading.Health_degraded
  ; "zombie", Reading.Health_zombie
  ]

let test_every_reading_gets_its_own_mark () =
  let marks = List.map (fun (_, r) -> Mark.glyph ~paused:false (Some r)) readings in
  let distinct = List.sort_uniq String.compare marks in
  check_int "six readings, six marks" (List.length readings) (List.length distinct)

let test_a_broken_keeper_does_not_draw_the_working_mark () =
  let working = Mark.glyph ~paused:false (Some Reading.Health_running) in
  List.iter
    (fun name_reading ->
      let name, reading = name_reading in
      check_bool (name ^ " reads differently from a working keeper") true
        (Mark.glyph ~paused:false (Some reading) <> working))
    [ "stale", Reading.Health_stale
    ; "degraded", Reading.Health_degraded
    ; "zombie", Reading.Health_zombie
    ; "offline", Reading.Health_offline
    ]

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
  check_bool "the legend covers offline" true (List.mem "offline" words);
  check_bool "the legend covers unread" true (List.mem "unread" words);
  check_string "a working keeper heads the legend" "healthy" (List.hd words)

let () =
  Alcotest.run "tui_keeper_mark"
    [ ( "marks"
      , [ Alcotest.test_case "every reading gets its own mark" `Quick
            test_every_reading_gets_its_own_mark
        ; Alcotest.test_case "a broken keeper does not draw the working mark"
            `Quick test_a_broken_keeper_does_not_draw_the_working_mark
        ; Alcotest.test_case "pause outranks the reading" `Quick
            test_pause_outranks_the_reading
        ; Alcotest.test_case "an unread roster is not a health" `Quick
            test_an_unread_roster_is_not_a_health
        ; Alcotest.test_case "every mark is one column wide" `Quick
            test_every_mark_is_one_column_wide
        ; Alcotest.test_case "the legend names every mark once" `Quick
            test_the_legend_names_every_mark_once
        ] )
    ]
