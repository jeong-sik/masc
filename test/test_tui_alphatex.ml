(* alphaTex text -> score -> tablature. The score reader is checked through
   the value the tab is drawn from: each beat on its count, each note on its
   string, and each failure as its constructor rather than the sentence shown
   for it. Of the drawing only what holds whatever a cell looks like is
   checked; where a row breaks and how wide a cell is are not compared. *)

module Score = Masc_tui_alphatex_score
module Alphatex = Masc_tui_alphatex

let failure : Score.failure Alcotest.testable =
  Alcotest.testable
    (fun ppf failure -> Format.pp_print_string ppf (Score.failure_text failure))
    ( = )

(* A score as (units, beats) for each measure; a beat as (start, span, notes);
   a note as "fret@string", with a [*] when technique markup rode on it. *)
let shape (score : Score.t) =
  List.map
    (fun (measure : Score.measure) ->
      ( measure.units
      , List.map
          (fun (beat : Score.beat) ->
            ( beat.start
            , beat.span
            , List.map
                (fun (note : Score.note) ->
                  Printf.sprintf "%s@%d%s" note.fret note.on_string
                    (if note.marked then "*" else ""))
                beat.notes ))
          measure.beats ))
    score.measures

let music =
  Alcotest.(result (list (pair int (list (triple int int (list string))))) failure)

let check_music label source expected =
  Alcotest.check music label (Ok expected) (Result.map shape (Score.read source))

let check_failure label source expected =
  Alcotest.check music label (Error expected) (Result.map shape (Score.read source))

(* {1 Music} *)

let spike_riff =
  ":4 0.6 3.6 5.6 3.6 | :8 5.6 3.6 :4 0.5 3.5 | :4 5.5 3.5 (2.4 0.3).2 | :1 \
   (3.6 2.5 0.4 0.3 3.2 3.1)"

let test_spike_riff () =
  check_music "four measures, each beat on its count" spike_riff
    [ 16, [ 0, 4, [ "0@6" ]; 4, 4, [ "3@6" ]; 8, 4, [ "5@6" ]; 12, 4, [ "3@6" ] ]
    ; 12, [ 0, 2, [ "5@6" ]; 2, 2, [ "3@6" ]; 4, 4, [ "0@5" ]; 8, 4, [ "3@5" ] ]
    ; 16, [ 0, 4, [ "5@5" ]; 4, 4, [ "3@5" ]; 8, 8, [ "2@4"; "0@3" ] ]
    ; 16, [ 0, 16, [ "3@6"; "2@5"; "0@4"; "0@3"; "3@2"; "3@1" ] ]
    ]

(* A rest takes its time and sounds nothing; [R] and [r.dur] are rests too. *)
let test_rests_take_their_time () =
  check_music "a quarter rest between two notes" ":4 0.6 r 3.6"
    [ 12, [ 0, 4, [ "0@6" ]; 4, 4, []; 8, 4, [ "3@6" ] ] ];
  check_music "an upper-case rest and one that says its length" ":4 R r.8 5.1"
    [ 8, [ 0, 4, []; 4, 2, []; 6, 2, [ "5@1" ] ] ]

(* The length last said holds until another is: across a bar line, and after
   a note, a chord or a rest that said its own. *)
let test_the_last_length_said_carries () =
  check_music "across a bar line" ":8 0.6 | 3.6"
    [ 2, [ 0, 2, [ "0@6" ] ]; 2, [ 0, 2, [ "3@6" ] ] ];
  check_music "after a note that said its own" "0.6.8 3.6 5.6"
    [ 6, [ 0, 2, [ "0@6" ]; 2, 2, [ "3@6" ]; 4, 2, [ "5@6" ] ] ];
  check_music "after a chord that said its own" "(0.6 2.5).2 3.6"
    [ 16, [ 0, 8, [ "0@6"; "2@5" ]; 8, 8, [ "3@6" ] ] ]

(* alphaTab's own samples write the length after the effects: 19.2{v f}.4 *)
let test_a_length_written_after_the_markup () =
  check_music "the half-note default gives way to the quarter" ":2 5.1{v f}.4 :8 7.1"
    [ 6, [ 0, 4, [ "5@1*" ]; 4, 2, [ "7@1" ] ] ]

let test_a_dead_note () =
  check_music "x is a fret" ":4 x.6 3.6" [ 8, [ 0, 4, [ "x@6" ]; 4, 4, [ "3@6" ] ] ]

(* Technique markup is not drawn, and the note it rode on is still there:
   same count, same string, same fret, marked. *)
let test_markup_marks_the_note_and_keeps_it () =
  check_music "after the beat" ":4 3.6 {h} 5.6"
    [ 8, [ 0, 4, [ "3@6*" ]; 4, 4, [ "5@6" ] ] ];
  check_music "across a bar line it is still the beat before" ":4 3.1 | {v} 5.1"
    [ 4, [ 0, 4, [ "3@1*" ] ]; 4, [ 0, 4, [ "5@1" ] ] ];
  check_music "on one member of a chord" ":4 (3.1{v f} 2.2)"
    [ 4, [ 0, 4, [ "3@1*"; "2@2" ] ] ];
  check_music "after a space, with parentheses of its own"
    ":1 (12.1 {sib} 14.2 {sib b (0 4)})"
    [ 16, [ 0, 16, [ "12@1*"; "14@2*" ] ] ]

let test_what_is_read_and_not_played () =
  check_music "comments" ":4 3.1 // to the end of the line\n5.1 /* or between */ 7.1"
    [ 12, [ 0, 4, [ "3@1" ]; 4, 4, [ "5@1" ]; 8, 4, [ "7@1" ] ] ];
  check_music "the directives and the dot that ends them"
    "\\title \"a \\\"quoted\\\" title\" \\tempo 99999999999999999999 \\ts 4 4 . :4 0.6"
    [ 4, [ 0, 4, [ "0@6" ] ] ];
  check_music "a bar line with nothing before it, or two together" "| :4 0.6 | | 3.6 |"
    [ 4, [ 0, 4, [ "0@6" ] ]; 4, [ 0, 4, [ "3@6" ] ] ]

let test_the_tuning_names_the_lines () =
  let tuning source =
    match Score.read source with
    | Ok score -> score.tuning
    | Error failure -> Alcotest.fail (Score.failure_text failure)
  in
  Alcotest.(check (list string)) "standard tuning when none is said"
    [ "e"; "B"; "G"; "D"; "A"; "E" ] (tuning ":4 0.6");
  Alcotest.(check (list string)) "the names as written, highest first"
    [ "E"; "B"; "G"; "D"; "A"; "D" ] (tuning "\\tuning E4 B3 G3 D3 A2 D2 :4 0.6")

(* {1 Repeats}

   The signs each bar carried: whether an [\ro] opened it, the [\rc] count
   that closed it, and the [\ae] numbers it plays on. *)

let signs_per_bar (score : Score.t) =
  List.map
    (fun (measure : Score.measure) -> (measure.repeat_start, measure.repeat_end, measure.endings))
    score.measures

let signs = Alcotest.(result (list (triple bool (option int) (list int))) failure)

let check_signs label source expected =
  Alcotest.check signs label (Ok expected) (Result.map signs_per_bar (Score.read source))

let test_a_repeat_opens_and_closes () =
  check_signs "open, then close with the count" "\\ro :4 0.6 3.6 | :4 5.6 3.6 \\rc 2"
    [ true, None, []; false, Some 2, [] ];
  check_signs "a sign stands anywhere in its bar" ":4 0.6 \\ro 3.6 | :4 \\rc 3 5.6"
    [ true, None, []; false, Some 3, [] ];
  check_signs "before the dot that ends the directives" "\\title \"riff\" \\ro . :4 0.6"
    [ true, None, [] ]

let test_a_second_close_says_the_count_again () =
  check_signs "the latest count wins" ":4 0.6 \\rc 2 \\rc 3" [ false, Some 3, [] ];
  check_signs "an opener twice is still open" "\\ro \\ro :4 0.6" [ true, None, [] ]

let test_endings_gather_across_the_bar () =
  check_signs "two directives, one set" ":4 0.6 \\ae 1 \\ae 2 3" [ false, None, [ 1; 2; 3 ] ];
  check_signs "ascending, no two alike" ":4 0.6 \\ae 3 1 3 2" [ false, None, [ 1; 2; 3 ] ];
  check_signs "each bar keeps its own" ":4 0.6 \\ae 1 | :4 3.6 \\ae 2"
    [ false, None, [ 1 ]; false, None, [ 2 ] ]

(* {1 The pane}

   Where the measures break and how wide a cell is are not compared: those
   are looked at on the screen. What a drawn tab owes whatever its cells look
   like is that no line passes the pane, and that a measure the pane cannot
   hold is the failure rather than a cut line. *)

let test_a_drawn_tab_stays_inside_the_pane () =
  match Alphatex.render_tab ~max_width:40 spike_riff with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
      Alcotest.(check bool) "something is drawn" true (not (List.is_empty lines));
      Alcotest.(check bool) "no line is wider than the pane" true
        (List.for_all (fun line -> String.length line <= 40) lines)

let test_a_measure_the_pane_cannot_hold () =
  match Alphatex.render_tab ~max_width:20 ":1 0.6 0.6" with
  | Error (Too_wide _) -> ()
  | Error other -> Alcotest.failf "not Too_wide: %s" (Alphatex.failure_text other)
  | Ok _ -> Alcotest.fail "a measure wider than the pane was drawn"

(* {1 Failures -- each is the fence arm's reason to show the source} *)

let test_what_never_closes () =
  check_failure "a comment" ":4 0.6 /* x" (Unclosed Comment);
  check_failure "a title" "\\title \"Canon Rock\n:4 0.6" (Unclosed Quoted_string);
  check_failure "an effect group" ":4 0.6 {h" (Unclosed Effect_group);
  check_failure "a chord" ":4 0.6 (3.6 0.4" (Unclosed Chord);
  check_failure "a bracket that closes nothing" ":4 0.6 )" (Closes_nothing ')');
  check_failure "a brace that closes nothing" ":4 0.6 }" (Closes_nothing '}')

let test_directives_outside_the_subset () =
  check_failure "a backslash and no name" "\\ :4 0.6" Backslash_without_name;
  check_failure "\\capo" "\\capo 2 :4 0.6" (Unknown_directive "capo");
  check_failure "a title with no text" "\\title :4 0.6" (Missing_argument Title_text);
  check_failure "a tempo with no number" "\\tempo :4 0.6" (Missing_argument Tempo_number);
  check_failure "a time signature with one number" "\\ts 4 :4 0.6"
    (Missing_argument Time_signature_numbers);
  check_failure "a tuning with no notes" "\\tuning :4 0.6" (Missing_argument Tuning_notes);
  check_failure "a quoted string that is no title" ":4 \"x\" 0.6" Quoted_without_title;
  check_failure "a second tuning"
    "\\tuning E4 B3 G3 D3 A2 E2 \\tuning D4 B3 G3 D3 A2 D2 :4 0.6" Second_tuning;
  check_failure "a tuning after the first note" ":4 0.6 \\tuning D4 A3" Tuning_after_music;
  check_failure "a tuning past twelve strings"
    ("\\tuning " ^ String.concat " " (List.init 13 (fun _ -> "E4")) ^ " :4 0.1")
    (Too_many_strings 13);
  check_failure "directives and no music" "\\title \"Canon\" \\tempo 120" No_music

(* A word that is not a duration, a note or a rest is not skipped: skipped,
   it would take its beat with it and move every note after it. *)
let test_a_word_is_never_skipped () =
  check_failure "a bare word" ":4 0.6 hello 3.6" (Not_a_note "hello");
  check_failure "a slide written into a note" ":4 3.6/5.6 0.5" (Not_a_note "3.6/5.6");
  check_failure "a repeat multiplier" ":4 3.6*4" (Not_a_note "3.6*4");
  check_failure "a rest with its dot missing" ":4 0.6 r4 3.6" (Not_a_note "r4");
  check_failure "a dot after the music has begun" ":4 3.1 . 5.1" (Not_a_note ".");
  check_failure "a length with no beat before it" ".8 3.1" (Not_a_note ".8");
  check_failure "a length on a chord member" ":4 (0.6.8 2.5)" (Not_a_note "0.6.8");
  check_failure "a fret with no string" ":4 36" (Not_a_note "36")

let test_lengths_outside_the_subset () =
  check_failure "a default length" ":3 0.6" (Duration_outside_subset ":3");
  check_failure "a note's own length" ":4 0.6.3" (Duration_outside_subset ".3");
  check_failure "a chord's length" "(0.6 2.5).3" (Duration_outside_subset ".3");
  check_failure "a chord's dot with nothing after it" "(0.6 2.5). 3.6"
    Chord_dot_without_duration

(* A dot, a tuplet or a grace note changes how long the beat lasts. Passed
   over like other markup, every later note would sit on the wrong count. *)
let test_markup_that_changes_length () =
  check_failure "a dotted note" ":4 0.6{d} 3.6" (Unsupported_rhythm "d");
  check_failure "a tuplet" ":8 0.6{tu 3} 3.6 5.6" (Unsupported_rhythm "tu 3");
  check_failure "a tuplet set for the notes after it" ":4 {tu 3} 3.1 4.1 5.1"
    (Unsupported_rhythm "tu 3");
  check_failure "a grace note" ":4 3.1{gr} 5.1" (Unsupported_rhythm "gr");
  check_failure "inside a chord" ":4 (3.1{d} 2.2)" (Unsupported_rhythm "d")

let test_notes_that_cannot_be_placed () =
  check_failure "markup with no note before it" "{v} :4 3.1" Effect_without_note;
  check_failure "an empty chord" ":4 () 3.6" Empty_chord;
  check_failure "two chord members on one string" ":4 (12.1 5.1)" (Chord_string_twice 1);
  check_failure "a fret past two digits" ":4 123.1" (Fret_out_of_range "123");
  check_failure "a seventh string on a six-string tuning" ":4 0.7"
    (String_past_tuning { string = 7; strings = 6 });
  check_failure "string zero" ":4 0.0" (String_past_tuning { string = 0; strings = 6 })

let test_repeat_signs_outside_the_subset () =
  check_failure "a close with no count" ":4 0.6 \\rc" (Missing_argument Repeat_count);
  check_failure "a close with no number" ":4 0.6 \\rc x" (Missing_argument Repeat_count);
  check_failure "a close at the bar line" ":4 0.6 \\rc | 3.6" (Missing_argument Repeat_count);
  check_failure "a count of nothing" ":4 0.6 \\rc 0" (Repeat_count_out_of_range "0");
  check_failure "a count past counting" ":4 0.6 \\rc 99999999999999999999"
    (Repeat_count_out_of_range "99999999999999999999");
  check_failure "endings with no numbers" ":4 0.6 \\ae" (Missing_argument Alternate_ending_numbers);
  check_failure "endings with no number" ":4 0.6 \\ae x" (Missing_argument Alternate_ending_numbers);
  check_failure "an ending of nothing" ":4 0.6 \\ae 0" (Alternate_ending_out_of_range "0");
  check_failure "an ending past 31" ":4 0.6 \\ae 32" (Alternate_ending_out_of_range "32");
  check_failure "the second ending past 31" ":4 0.6 \\ae 1 32" (Alternate_ending_out_of_range "32")

let test_a_sign_with_no_bar () =
  check_failure "an opener after the last bar" ":4 0.6 | \\ro" Repeat_without_bar;
  check_failure "a closer after the last bar" ":4 0.6 | \\rc 2" Repeat_without_bar;
  check_failure "endings after the last bar" ":4 0.6 | \\ae 1" Repeat_without_bar;
  check_failure "an opener on an empty bar" "\\ro | :4 0.6" Repeat_without_bar;
  check_failure "a closer on an empty bar" ":4 0.6 | \\rc 2 | 3.6" Repeat_without_bar

(* A failure's sentence is printed, so the author's text in it never reaches
   the terminal as control bytes. *)
let test_a_failure_sentence_holds_no_control_bytes () =
  List.iter
    (fun word ->
      String.iter
        (fun char ->
          Alcotest.(check bool)
            (Printf.sprintf "no control byte for %S" word)
            true
            (Char.code char >= 0x20 && char <> '\x7f'))
        (Score.failure_text (Score.Not_a_note word)))
    [ "a\000b"; "a\x01b"; "a\x7fb"; "a\nb"; "tab\there" ]

let () =
  Alcotest.run "tui-alphatex"
    [ ( "music"
      , [ Alcotest.test_case "the spike riff" `Quick test_spike_riff
        ; Alcotest.test_case "rests take their time" `Quick test_rests_take_their_time
        ; Alcotest.test_case "the last length said carries" `Quick
            test_the_last_length_said_carries
        ; Alcotest.test_case "a length written after the markup" `Quick
            test_a_length_written_after_the_markup
        ; Alcotest.test_case "a dead note" `Quick test_a_dead_note
        ; Alcotest.test_case "markup marks the note and keeps it" `Quick
            test_markup_marks_the_note_and_keeps_it
        ; Alcotest.test_case "what is read and not played" `Quick
            test_what_is_read_and_not_played
        ; Alcotest.test_case "the tuning names the lines" `Quick
            test_the_tuning_names_the_lines
        ] )
    ; ( "repeats"
      , [ Alcotest.test_case "a repeat opens and closes" `Quick
            test_a_repeat_opens_and_closes
        ; Alcotest.test_case "a second close says the count again" `Quick
            test_a_second_close_says_the_count_again
        ; Alcotest.test_case "endings gather across the bar" `Quick
            test_endings_gather_across_the_bar
        ] )
    ; ( "the pane"
      , [ Alcotest.test_case "a drawn tab stays inside the pane" `Quick
            test_a_drawn_tab_stays_inside_the_pane
        ; Alcotest.test_case "a measure the pane cannot hold" `Quick
            test_a_measure_the_pane_cannot_hold
        ] )
    ; ( "failures"
      , [ Alcotest.test_case "what never closes" `Quick test_what_never_closes
        ; Alcotest.test_case "directives outside the subset" `Quick
            test_directives_outside_the_subset
        ; Alcotest.test_case "a word is never skipped" `Quick
            test_a_word_is_never_skipped
        ; Alcotest.test_case "lengths outside the subset" `Quick
            test_lengths_outside_the_subset
        ; Alcotest.test_case "markup that changes length" `Quick
            test_markup_that_changes_length
        ; Alcotest.test_case "notes that cannot be placed" `Quick
            test_notes_that_cannot_be_placed
        ; Alcotest.test_case "repeat signs outside the subset" `Quick
            test_repeat_signs_outside_the_subset
        ; Alcotest.test_case "a sign with no bar" `Quick test_a_sign_with_no_bar
        ; Alcotest.test_case "a failure sentence holds no control bytes" `Quick
            test_a_failure_sentence_holds_no_control_bytes
        ] )
    ]
