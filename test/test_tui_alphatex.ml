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
   a note as "fret@string", led by a [-] when it is tied and held on from the
   note before it, with a [*] when technique markup rode on it. *)
let shape (score : Score.t) =
  List.map
    (fun (measure : Score.measure) ->
      ( measure.ticks
      , List.map
          (fun (beat : Score.beat) ->
            ( beat.start
            , beat.span
            , ( beat.marked
              , List.map
                  (fun (note : Score.note) ->
                    Printf.sprintf "%s%s@%d%s"
                      (match note.attack with
                       | Score.Struck | Score.Muted -> ""
                       | Score.Tied -> "-")
                      note.fret note.on_string
                      (if note.marked then "*" else ""))
                  beat.notes ) ))
          measure.beats ))
    score.measures

let music =
  Alcotest.(result (list (pair int (list (triple int int (pair bool (list string)))))) failure)

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
    [ 384, [ 0, 96, ( false, [ "0@6" ] ); 96, 96, ( false, [ "3@6" ] ); 192, 96, ( false, [ "5@6" ] )
           ; 288, 96, ( false, [ "3@6" ] ) ]
    ; 288, [ 0, 48, ( false, [ "5@6" ] ); 48, 48, ( false, [ "3@6" ] ); 96, 96, ( false, [ "0@5" ] )
           ; 192, 96, ( false, [ "3@5" ] ) ]
    ; 384, [ 0, 96, ( false, [ "5@5" ] ); 96, 96, ( false, [ "3@5" ] ); 192, 192, ( false, [ "2@4"; "0@3" ] ) ]
    ; 384, [ 0, 384, ( false, [ "3@6"; "2@5"; "0@4"; "0@3"; "3@2"; "3@1" ] ) ]
    ]

(* A rest takes its time and sounds nothing; [R] and [r.dur] are rests too. *)
let test_rests_take_their_time () =
  check_music "a quarter rest between two notes" ":4 0.6 r 3.6"
    [ 288, [ 0, 96, ( false, [ "0@6" ] ); 96, 96, ( false, [] ); 192, 96, ( false, [ "3@6" ] ) ] ];
  check_music "an upper-case rest and one that says its length" ":4 R r.8 5.1"
    [ 192, [ 0, 96, ( false, [] ); 96, 48, ( false, [] ); 144, 48, ( false, [ "5@1" ] ) ] ]

(* The length last said holds until another is: across a bar line, and after
   a note, a chord or a rest that said its own. *)
let test_the_last_length_said_carries () =
  check_music "across a bar line" ":8 0.6 | 3.6"
    [ 48, [ 0, 48, ( false, [ "0@6" ] ) ]; 48, [ 0, 48, ( false, [ "3@6" ] ) ] ];
  check_music "after a note that said its own" "0.6.8 3.6 5.6"
    [ 144, [ 0, 48, ( false, [ "0@6" ] ); 48, 48, ( false, [ "3@6" ] ); 96, 48, ( false, [ "5@6" ] ) ] ];
  check_music "after a chord that said its own" "(0.6 2.5).2 3.6"
    [ 384, [ 0, 192, ( false, [ "0@6"; "2@5" ] ); 192, 192, ( false, [ "3@6" ] ) ] ]

(* alphaTab's own samples write the length after the effects: 19.2{v f}.4 *)
let test_a_length_written_after_the_markup () =
  check_music "the half-note default gives way to the quarter" ":2 5.1{v f}.4 :8 7.1"
    [ 144, [ 0, 96, ( false, [ "5@1*" ] ); 96, 48, ( false, [ "7@1" ] ) ] ]

let test_a_dead_note () =
  check_music "x is a fret" ":4 x.6 3.6"
    [ 192, [ 0, 96, ( false, [ "x@6" ] ); 96, 96, ( false, [ "3@6" ] ) ] ]

(* [-] where the fret goes is a tie, not a rest: the note holds the fret of
   the latest earlier note on its string. alphaTab 1.8.4 read every case
   below the same way (Note.findTieOrigin). *)
let test_a_tie_holds_the_note_before_it () =
  check_music "on the next beat" ":4 7.4 -.4"
    [ 192, [ 0, 96, ( false, [ "7@4" ] ); 96, 96, ( false, [ "-7@4" ] ) ] ];
  check_music "past a rest" ":4 7.4 r -.4"
    [ 288, [ 0, 96, ( false, [ "7@4" ] ); 96, 96, ( false, [] ); 192, 96, ( false, [ "-7@4" ] ) ] ];
  check_music "past a note on another string" ":4 7.4 5.3 -.4"
    [ 288, [ 0, 96, ( false, [ "7@4" ] ); 96, 96, ( false, [ "5@3" ] ); 192, 96, ( false, [ "-7@4" ] ) ] ];
  check_music "a tie held by a tie" ":4 7.4 -.4 -.4"
    [ 288, [ 0, 96, ( false, [ "7@4" ] ); 96, 96, ( false, [ "-7@4" ] ); 192, 96, ( false, [ "-7@4" ] ) ] ];
  check_music "across a bar line, with its own length" ":4 7.4 | -.4.8"
    [ 96, [ 0, 96, ( false, [ "7@4" ] ) ]; 48, [ 0, 48, ( false, [ "-7@4" ] ) ] ];
  check_music "three bars back" ":4 7.4 | 5.3 | 5.3 | -.4"
    [ 96, [ 0, 96, ( false, [ "7@4" ] ) ]; 96, [ 0, 96, ( false, [ "5@3" ] ) ]
    ; 96, [ 0, 96, ( false, [ "5@3" ] ) ]; 96, [ 0, 96, ( false, [ "-7@4" ] ) ] ];
  check_music "chord members" ":4 (7.4 5.3) (-.4 -.3)"
    [ 192, [ 0, 96, ( false, [ "7@4"; "5@3" ] ); 96, 96, ( false, [ "-7@4"; "-5@3" ] ) ] ];
  check_music "with markup after it" ":4 7.4 -.4{h}"
    [ 192, [ 0, 96, ( false, [ "7@4" ] ); 96, 96, ( false, [ "-7@4*" ] ) ] ];
  check_music "past a directive, which opens alphaTab's next bar" ":4 7.4 \\tempo 90 -.4"
    [ 192, [ 0, 96, ( false, [ "7@4" ] ); 96, 96, ( false, [ "-7@4" ] ) ] ];
  (* alphaTab plays these as an open string, which [-] does not say. *)
  check_failure "with no note before it" ":4 -.4 3.3" (Tie_without_note 4);
  check_failure "with the note only on another string" ":4 7.3 -.4" (Tie_without_note 4);
  check_failure "four bars back" ":4 7.4 | 5.3 | 5.3 | 5.3 | -.4" (Tie_without_note 4);
  check_failure "empty bars count as bars" ":4 7.4 | | | | -.4" (Tie_without_note 4);
  check_failure "a bar a directive opened counts as a bar" ":4 7.4 | r | r \\ts 3 4 r | -.4"
    (Tie_without_note 4);
  check_failure "holding a dead note" ":4 x.4 -.4" (Tie_to_dead_note 4);
  check_failure "a chord member holds no member of its own chord" ":4 (7.4 -.3)"
    (Tie_without_note 3);
  check_failure "on a string the tuning lacks" ":4 7.6 -.7"
    (String_past_tuning { string = 7; strings = 6 });
  check_failure "a dash with no string" ":4 7.4 -" (Not_a_note "-")

(* The Bass VI solo a Keeper sent on 2026-10-21 failed the whole preview at
   its first [-.4.8]. Its first bar, as alphaTab 1.8.4 reads it. *)
let test_a_bass_vi_line_with_ties () =
  check_music "ties after notes on the same string"
    "\\title \"Bamseom - Solo Rise v1\"\n\
     \\tempo 76\n\
     \\instrument 34\n\
     \\tuning E3 B2 G2 D2 A1 E1\n\
     \\clef f4\n\
     .\n\
     \\ts 4 4\n\
     3.5.8{txt \"C | C major tones\"} 5.2.16 5.3.16 7.4.4 -.4.8 5.4.4 -.4.8 |"
    [ 384, [ 0, 48, ( false, [ "3@5*" ] ); 48, 24, ( false, [ "5@2" ] ); 72, 24, ( false, [ "5@3" ] )
           ; 96, 96, ( false, [ "7@4" ] ); 192, 48, ( false, [ "-7@4" ] ); 240, 96, ( false, [ "5@4" ] )
           ; 336, 48, ( false, [ "-5@4" ] ) ] ]

(* Technique markup is not drawn, and the note it rode on is still there:
   same count, same string, same fret, marked. *)
let test_markup_marks_the_note_and_keeps_it () =
  check_music "after the beat" ":4 3.6 {h} 5.6"
    [ 192, [ 0, 96, ( false, [ "3@6*" ] ); 96, 96, ( false, [ "5@6" ] ) ] ];
  check_music "across a bar line it is still the beat before" ":4 3.1 | {v} 5.1"
    [ 96, [ 0, 96, ( false, [ "3@1*" ] ) ]; 96, [ 0, 96, ( false, [ "5@1" ] ) ] ];
  check_music "on one member of a chord" ":4 (3.1{v f} 2.2)"
    [ 96, [ 0, 96, ( false, [ "3@1*"; "2@2" ] ) ] ];
  check_music "after a space, with parentheses of its own"
    ":1 (12.1 {sib} 14.2 {sib b (0 4)})"
    [ 384, [ 0, 384, ( false, [ "12@1*"; "14@2*" ] ) ] ]

let test_what_is_read_and_not_played () =
  check_music "comments" ":4 3.1 // to the end of the line\n5.1 /* or between */ 7.1"
    [ 288, [ 0, 96, ( false, [ "3@1" ] ); 96, 96, ( false, [ "5@1" ] ); 192, 96, ( false, [ "7@1" ] ) ] ];
  check_music "the directives and the dot that ends them"
    "\\title \"a \\\"quoted\\\" title\" \\tempo 99999999999999999999 \\ts 4 4 . :4 0.6"
    [ 96, [ 0, 96, ( false, [ "0@6" ] ) ] ];
  check_music "a bar line with nothing before it, or two together" "| :4 0.6 | | 3.6 |"
    [ 96, [ 0, 96, ( false, [ "0@6" ] ) ]; 96, [ 0, 96, ( false, [ "3@6" ] ) ] ]

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

let documented_bass_score =
  {|\title "베이스 스케치 11/8"
\subtitle "11/8 워밍업"
\artist "Example Artist"
\track "Bass" { instrument "Electric Bass Finger" }
\staff { tabs }
\tuning (G2 D2 A1 E1)
\clef bass
\ks C#minor
\tempo 116 // estimated tempo
\ts 11 8
\section "Intro 4+4+3"
:8 4.3 4.3 4.3 4.3 0.3 0.3 0.3 0.3 4.3 7.3 4.3 |
|}

let test_documented_bass_score () =
  let expected_beats =
    List.mapi
      (fun index fret -> index * 48, 48, (false, [ fret ^ "@3" ]))
      [ "4"; "4"; "4"; "4"; "0"; "0"; "0"; "0"; "4"; "7"; "4" ]
  in
  check_music "eleven eighth notes retain their frets and positions"
    documented_bass_score [ 528, expected_beats ];
  match Score.read documented_bass_score with
  | Error failure -> Alcotest.fail (Score.failure_text failure)
  | Ok score ->
      Alcotest.(check (list string)) "four bass strings, highest first"
        [ "G"; "D"; "A"; "E" ] score.tuning;
      Alcotest.(check (option string)) "the title is retained"
        (Some "베이스 스케치 11/8") score.title;
      Alcotest.(check (option string)) "the subtitle is retained"
        (Some "11/8 워밍업") score.subtitle;
      Alcotest.(check (option int)) "tempo is retained" (Some 116) score.tempo;
      Alcotest.(check (option (pair int int))) "meter is retained"
        (Some (11, 8)) score.time_signature

let test_standalone_instrument_keeps_bass_vi_music () =
  let metadata = {|\title "Bass VI"
\tempo 80
\instrument 34
\tuning E3 B2 G2 D2 A1 E1
.
\ts 4 4
|} in
  check_music "Bass VI opens C, C-sharp, D on string five"
    (metadata ^ ":8 3.5 4.5 :4 5.5 :2 r")
    [384, [0, 48, (false, ["3@5"]); 48, 48, (false, ["4@5"]);
      96, 96, (false, ["5@5"]); 192, 192, (false, [])]];
  (match Score.read (metadata ^ ":8 3.5 4.5 :4 5.5 :2 r") with
   | Error failure -> Alcotest.fail (Score.failure_text failure)
   | Ok score -> Alcotest.(check (list string)) "six explicitly tuned strings"
       ["E"; "B"; "G"; "D"; "A"; "E"] score.tuning);
  check_failure "standalone instrument still needs explicit tuning"
    "\\instrument 34 :4 3.5" Instrument_without_tuning;
  check_failure "track naming cannot erase the instrument's tuning requirement"
    "\\instrument 34 \\track \"Bass\" :4 3.5" Instrument_without_tuning;
  check_failure "unsupported timbre is not silently discarded"
    "\\instrument 0 \\tuning E3 B2 G2 D2 A1 E1 :4 3.5" (Unsupported_instrument "0");
  check_failure "missing instrument value is retained as a failure"
    "\\instrument \\tuning E3 B2 G2 D2 A1 E1 :4 3.5" (Missing_argument Instrument_name);
  check_failure "later instrument changes require the full score view"
    ":4 3.5 \\instrument 34" Instrument_after_music

let test_parenthesized_tuning_members_are_checked () =
  check_music "whitespace and comments inside the tuning list"
    "\\tuning (G2\nD2 /* middle */ A1\tE1) :8 4.3"
    [ 48, [ 0, 48, (false, [ "4@3" ]) ] ];
  List.iter
    (fun inner ->
      check_failure "every grouped tuning member must be a note name"
        ("\\tuning (" ^ inner ^ ") :8 4.3") (Invalid_tuning_group inner))
    [ "G2 D2 4.3 E1"; "G2 D2 | E1"; "G2 D2 {tabs} E1"; "\"G2\" D2 A1 E1" ];
  check_failure "a tuning list cannot carry a beat duration"
    "\\tuning (G2 D2 A1 E1).8 :8 4.3" (Invalid_tuning_group "G2 D2 A1 E1");
  check_failure "an empty tuning list has no strings"
    "\\tuning () :8 4.3" (Missing_argument Tuning_notes);
  check_failure "the explicit bass tuning rejects a fifth string"
    "\\tuning (G2 D2 A1 E1) :8 0.5" (String_past_tuning { string = 5; strings = 4 })

let test_single_part_metadata_keeps_music () =
  check_music "track names and staff properties do not consume the first beat"
    "\\track \"Guitar\" \"gtr\" \\staff {score tabs} :4 0.6"
    [ 96, [ 0, 96, (false, [ "0@6" ]) ] ];
  check_music "numeric bass program uses the explicit tuning"
    "\\track {instrument 33} \\staff \\tuning (G2 D2 A1 E1) :8 0.4"
    [ 48, [ 0, 48, (false, [ "0@4" ]) ] ];
  check_music "a key and section after a bar line keep both measures"
    "\\ks C#minor \\section \"Intro\" :8 4.3 | \\ks Emajor \\section \"S\" \"Solo\" 7.3"
    [ 48, [ 0, 48, (false, [ "4@3" ]) ]; 48, [ 0, 48, (false, [ "7@3" ]) ] ]

let test_multiple_parts_are_not_flattened () =
  List.iter
    (fun source -> check_failure "an additional track is a separate timeline" source Additional_track)
    [ "\\track \"A\" \\track \"B\" :4 0.6"
    ; "\\staff {tabs} \\track \"B\" :4 0.6"
    ; ":4 0.6 \\track \"B\" 3.6"
    ; "\\track \"A\" :4 0.6 | \\track \"B\" 3.6" ];
  List.iter
    (fun source -> check_failure "an additional staff is a separate timeline" source Additional_staff)
    [ "\\staff {tabs} \\staff {tabs} :4 0.6"
    ; ":4 0.6 \\staff {tabs} 3.6"
    ; "\\track \"A\" \\staff {tabs} :4 0.6 | \\staff {tabs} 3.6" ]

let test_instrument_and_staff_do_not_guess () =
  check_failure "a bass instrument alone does not inherit guitar strings"
    "\\track \"Bass\" {instrument \"Electric Bass Finger\"} :8 0.3"
    Instrument_without_tuning;
  check_failure "a later tuning cannot correct notes already read"
    "\\track {instrument 33} :8 0.3 \\tuning (G2 D2 A1 E1)"
    Instrument_without_tuning;
  check_failure "percussion is not fret-and-string music"
    "\\track {instrument percussion} \\tuning (G2 D2 A1 E1) :8 0.3"
    (Unsupported_instrument "percussion");
  check_failure "an unknown instrument is not silently accepted"
    "\\track {instrument \"Imaginary Bass\"} \\tuning (G2 D2 A1 E1) :8 0.3"
    (Unsupported_instrument "Imaginary Bass");
  check_failure "track properties require the supported argument shape"
    "\\track {instrument 33 mute} \\tuning (G2 D2 A1 E1) :8 0.3"
    (Unsupported_track_properties "instrument 33 mute");
  List.iter
    (fun properties ->
      check_failure "a non-tab staff is not turned into tablature"
        ("\\staff {" ^ properties ^ "} :8 0.3") (Unsupported_staff_properties properties))
    [ "score"; "percussion"; "numbered"; "tabs slash" ]

let test_metadata_arguments_and_bar_boundaries () =
  check_failure "artist needs text" "\\artist :8 0.3" (Missing_argument Artist_text);
  check_failure "subtitle needs text" "\\subtitle :8 0.3" (Missing_argument Subtitle_text);
  check_failure "section needs text" "\\section :8 0.3" (Missing_argument Section_text);
  check_failure "key signature needs a name" "\\ks \\ts 4 4 :8 0.3"
    (Missing_argument Key_signature_name);
  check_failure "unknown key signatures are not skipped" "\\ks Hminor :8 0.3"
    (Invalid_key_signature "Hminor");
  check_failure "a clef needs a name" "\\clef \\ts 4 4 :8 0.3"
    (Missing_argument Clef_name);
  check_failure "unknown clefs are not skipped" "\\clef soprano :8 0.3"
    (Invalid_clef "soprano");
  check_music "a clef names the staff and changes no fret"
    "\\clef bass :8 4.3 | \\clef treble 7.3"
    [ 48, [ 0, 48, (false, [ "4@3" ]) ]; 48, [ 0, 48, (false, [ "7@3" ]) ] ];
  check_failure "a section cannot silently erase an implicit bar boundary"
    ":8 4.3 \\section \"Solo\" 7.3" Section_after_note;
  check_failure "a key change cannot silently erase an implicit bar boundary"
    ":8 4.3 \\ks Emajor 7.3" Key_signature_after_note;
  check_failure "a clef change cannot silently erase an implicit bar boundary"
    ":8 4.3 \\clef bass 7.3" Clef_after_note

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

(* alphaTab's own syntax and the writer's canonical form wrap several endings
   in parentheses; a single ending may carry them or not. *)
let test_endings_read_alphaTabs_parenthesized_form () =
  check_signs "parenthesized members are the list" ":4 0.6 \\ae (1 2 3)"
    [ false, None, [ 1; 2; 3 ] ];
  check_signs "one member may keep the parentheses" ":4 0.6 \\ae (2)"
    [ false, None, [ 2 ] ];
  check_signs "one member may drop the parentheses" ":4 0.6 \\ae 4"
    [ false, None, [ 4 ] ];
  check_signs "parentheses then music, alphaTab's example"
    "\\ro :4 0.6 | \\ae (1 2 3) :4 3.6 \\rc 2"
    [ true, None, []; false, Some 2, [ 1; 2; 3 ] ]

(* The endings stop where the music resumes: the note after them still
   sounds on its count. *)
let test_endings_stop_where_music_resumes () =
  check_music "the note after the endings keeps its beat" ":4 0.6 \\ae 1 3.6"
    [ 192, [ 0, 96, ( false, [ "0@6" ] ); 96, 96, ( false, [ "3@6" ] ) ] ];
  check_signs "and the bar keeps its ending" ":4 0.6 \\ae 1 3.6" [ false, None, [ 1 ] ]

let test_all_marks_on_one_bar () =
  check_signs "open, endings and close together" "\\ro \\ae 1 :4 0.6 \\rc 2"
    [ true, Some 2, [ 1 ] ];
  (match Alphatex.render_tab ~max_width:40 "\\ro \\ae 1 :4 0.6 \\rc 2" with
   | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
   | Ok lines ->
       Alcotest.(check bool) "no line is wider than the pane" true
         (List.for_all (fun line -> String.length line <= 40) lines))

let test_counts_at_their_edges () =
  check_signs "a count of one plays once" ":4 0.6 \\rc 1" [ false, Some 1, [] ];
  check_signs "the thirty-first ending" ":4 0.6 \\ae 31" [ false, None, [ 31 ] ]

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
  | Error (Unreadable _ as other) -> Alcotest.failf "not Too_wide: %s" (Alphatex.failure_text other)
  | Ok _ -> Alcotest.fail "a measure wider than the pane was drawn"

(* Two beats whose texts are wider than the ticks they hold (two-letter
   frets on sixteenths, a grace note ahead of a full beat) must not overwrite
   each other: the second keeps its own cells, so the first is still there. *)
let test_wide_note_text_does_not_overwrite_the_next_beat () =
  let string_row lines =
    (* The first string line after the measure-number row holds string 1,
       the high E these frets are written on. *)
    List.nth lines 1
  in
  match Alphatex.render_tab ~max_width:40 ":16 12.1 10.1" with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
    let row = string_row lines in
    let content = String.sub row 2 (String.length row - 2) in
    Alcotest.(check bool) "both two-letter frets are drawn, the first intact" true
      (let rec has_both i =
         i + 5 <= String.length content
         && ((content.[i] = '1' && content.[i + 1] = '2' && content.[i + 2] = '-'
              && content.[i + 3] = '1' && content.[i + 4] = '0')
             || has_both (i + 1))
       in
       has_both 0);
    (* A grace note with a two-letter fret must hold both cells, or the note
       it leads into draws over its second digit. *)
    (match Alphatex.render_tab ~max_width:40 ":4 12.1{gr} 5.1" with
     | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
     | Ok lines ->
       let row = string_row lines in
       let content = String.sub row 2 (String.length row - 2) in
       Alcotest.(check bool) "a two-letter grace note is not overwritten" true
         (let rec has_grace i =
            i + 4 <= String.length content
            && ((content.[i] = '1' && content.[i + 1] = '2' && content.[i + 2] = '-'
                 && content.[i + 3] = '5')
                || has_grace (i + 1))
          in
          has_grace 0))

(* The rhythm line rides under the lowest string: it is the beat letters
   [w h q e s] at their beats' first cells, with the same left lead and
   barlines as the string lines. *)
let test_the_rhythm_line_names_each_beat () =
  match Alphatex.render_tab ~rhythm:true ~max_width:60 ":4 0.6 3.6 :8 5.6 3.6" with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
      (* The measure numbers ride ahead of the strings, so the block is the
         numbers, the six strings and the rhythm line. *)
      Alcotest.(check int) "the rhythm line is one more than the strings" 8
        (List.length lines);
      let rhythm = List.nth lines 7 in
      (* One-letter tuning names give a lead of [name + bar] = two cells. *)
      Alcotest.(check bool) "the rhythm lead is blank, one wide as a line name" true
        (String.length rhythm >= 2 && rhythm.[0] = ' ' && rhythm.[1] = '|');
      Alcotest.(check char) "the first beat is a quarter" 'q' rhythm.[2];
      Alcotest.(check char) "the second beat is a quarter" 'q' rhythm.[6];
      Alcotest.(check char) "the third beat is an eighth" 'e' rhythm.[10];
      Alcotest.(check char) "the fourth beat is an eighth" 'e' rhythm.[12];
      Alcotest.(check bool) "no letter rides the string lines' cells" true
        (List.for_all
           (fun line ->
             let cells = String.sub line 2 (String.length line - 2) in
             not (List.exists (fun letter -> String.contains cells letter) [ 'w'; 'h'; 'q'; 'e'; 's' ]))
           (List.filteri (fun i _ -> i > 0 && i < 7) lines))

let test_the_rhythm_line_without_the_word_is_not_there () =
  let score = ":4 0.6 3.6 :8 5.6 3.6" in
  match
    ( Alphatex.render_tab ~max_width:60 score,
      Alphatex.render_tab ~rhythm:true ~max_width:60 score )
  with
  | Error failure, _ | _, Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok without, Ok with_rhythm ->
      Alcotest.(check int) "the default keeps the numbers and six lines" 7 (List.length without);
      Alcotest.(check bool) "the default line count is one less" true
        (List.length with_rhythm = List.length without + 1);
      List.iter2
        (fun plain drawn ->
          Alcotest.(check string) "the default draws the same line" plain drawn)
        without (List.filteri (fun i _ -> i < List.length without) with_rhythm)

let test_the_rhythm_line_fills_between_beats () =
  (* [":1"] makes whole notes the default, so four beats fill 64 cells; the
     pane is the full 80 so the measure fits and the letters can be read. *)
  match Alphatex.render_tab ~rhythm:true ~max_width:80 ":1 0.6 3.6 5.6 3.6" with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
      let rhythm = List.nth lines 7 in
      Alcotest.(check char) "every whole beat says w at its first cell" 'w' rhythm.[2];
      Alcotest.(check char) "the second whole beat too" 'w' rhythm.[18];
      Alcotest.(check bool) "the letters are one per beat" true
        (String.for_all
           (fun c -> c = '-' || c = 'w' || c = '|' || c = ' ')
           (String.sub rhythm 2 (String.length rhythm - 2)))

let repeated_riff =
  "\\ro :4 0.6 3.6 5.6 3.6 | :8 5.6 3.6 :4 0.5 \\rc 2 | \\ae 1 :4 5.5 3.5 | \\ae 2 :4 5.5 \
   \\rc 2"

let test_a_repeated_tab_stays_inside_the_pane () =
  match Alphatex.render_tab ~max_width:40 repeated_riff with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
      Alcotest.(check bool) "something is drawn" true (not (List.is_empty lines));
      Alcotest.(check bool) "no line is wider than the pane" true
        (List.for_all (fun line -> String.length line <= 40) lines)

let test_a_repeated_measure_the_pane_cannot_hold () =
  match Alphatex.render_tab ~max_width:20 "\\ro :1 0.6 0.6 \\rc 12" with
  | Error (Too_wide _) -> ()
  | Error (Unreadable _ as other) -> Alcotest.failf "not Too_wide: %s" (Alphatex.failure_text other)
  | Ok _ -> Alcotest.fail "a measure wider than the pane was drawn"

(* {1 The header}

   [\title] [\tempo] and [\ts] are kept on the score now: the pane draws
   them on one line ahead of the tab and numbers each measure above its
   system. *)

let contains_substring haystack needle =
  let haystack_len = String.length haystack and needle_len = String.length needle in
  let rec go index =
    index + needle_len <= haystack_len
    && (String.sub haystack index needle_len = needle || go (index + 1))
  in
  needle_len = 0 || go 0

let read_score source =
  match Score.read source with
  | Ok score -> score
  | Error failure -> Alcotest.fail (Score.failure_text failure)

(* %S-style quoting escapes every byte past ASCII into decimal escapes, so
   a Korean title would render as numbers: the rendered lines must carry the
   UTF-8 title bytes intact. *)
let test_header_line_keeps_a_non_ascii_title () =
  match Alphatex.render_tab ~max_width:80 "\\title \"리프\" \\tempo 90 :4 0.6" with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
      Alcotest.(check bool) "the UTF-8 title bytes survive unescaped" true
        (List.exists (fun line -> contains_substring line "리프") lines)

(* The subtitle is the author's text; the parser keeps it the way it keeps a
   title, including the UTF-8 bytes of a Korean subtitle, and the last one
   said wins. The header that draws it is seen by eye, not asserted here. *)
let test_subtitle_is_kept () =
  let score = read_score "\\subtitle \"서울 야경\" :4 0.6" in
  Alcotest.(check (option string)) "the subtitle" (Some "서울 야경")
    score.subtitle;
  Alcotest.(check (option string)) "no title said" None score.title

let test_last_subtitle_wins () =
  let score =
    read_score "\\subtitle \"first\" \\subtitle \"second\" :4 0.6"
  in
  Alcotest.(check (option string)) "the last subtitle" (Some "second")
    score.subtitle

let test_directives_are_kept () =
  let score = read_score "\\title \"Riff\" \\subtitle \"Warm-up\" \\tempo 92 \\ts 6 8 :4 0.6" in
  Alcotest.(check (option string)) "the title" (Some "Riff") score.title;
  Alcotest.(check (option string)) "the subtitle" (Some "Warm-up") score.subtitle;
  Alcotest.(check (option int)) "the tempo" (Some 92) score.tempo;
  Alcotest.(check (option (pair int int))) "the time signature" (Some (6, 8))
    score.time_signature

let test_directives_absent_are_none () =
  let score = read_score ":4 0.6" in
  Alcotest.(check (option string)) "no title" None score.title;
  Alcotest.(check (option string)) "no subtitle" None score.subtitle;
  Alcotest.(check (option int)) "no tempo" None score.tempo;
  Alcotest.(check (option (pair int int))) "no time signature" None
    score.time_signature

let test_header_line_drawn () =
  match
    Alphatex.render_tab ~max_width:80 "\\title \"Riff\" \\tempo 92 \\ts 4 4 :4 0.6 3.6"
  with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
      let headers =
        List.filter (fun line -> contains_substring line "♩=") lines
      in
      Alcotest.(check int) "exactly one header line" 1 (List.length headers);
      let header = List.hd headers in
      List.iter
        (fun piece ->
           Alcotest.(check bool)
             (Printf.sprintf "%S is in the header" piece)
             true (contains_substring header piece))
        [ "♩=92"; "4/4"; "\"Riff\"" ]

let test_header_line_absent_when_no_directives () =
  match Alphatex.render_tab ~max_width:80 ":4 0.6" with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
      Alcotest.(check bool) "no header line without directives" false
        (List.exists (fun line -> contains_substring line "♩=") lines)

let test_measure_numbers_climb_with_the_measures () =
  match
    Alphatex.render_tab ~max_width:80 ":4 0.6 3.6 | :4 5.6 7.6 | :4 0.6 3.6 | :4 5.6 7.6"
  with
  | Error failure -> Alcotest.fail (Alphatex.failure_text failure)
  | Ok lines ->
      (* Without directives the first drawn row is the measure numbers. *)
      let numbers = List.hd lines in
      let index_of digit = String.index_opt numbers (Char.chr (Char.code '0' + digit)) in
      (match index_of 1, index_of 2, index_of 3, index_of 4 with
       | Some at1, Some at2, Some at3, Some at4 ->
           Alcotest.(check bool) "the numbers climb with the measures" true
             (at1 < at2 && at2 < at3 && at3 < at4)
       | _ -> Alcotest.fail "not every measure number was drawn")

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
  check_failure "a quoted string with no metadata directive" ":4 \"x\" 0.6" Quoted_without_metadata;
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
(* A dot, a double dot, a tuplet or a grace note changes the latest beat's
   length. A dotted quarter is 144 ticks, a double-dotted half is 336, and a
   triplet quarter is 64 -- all exact in the 384-tick whole note. A grace
   note takes no time: the note after it still sits where the plain length
   put it. *)
let test_markup_that_changes_length () =
  check_music "a dotted note" ":4 0.6{d} 3.6"
    [ 240, [ 0, 144, ( true, [ "0@6" ] ); 144, 96, ( false, [ "3@6" ] ) ] ];
  check_music "a double-dotted note" ":2 0.6{dd} 3.6"
    [ 528, [ 0, 336, ( true, [ "0@6" ] ); 336, 192, ( false, [ "3@6" ] ) ] ];
  check_music "a triplet quarter" ":4 0.6{tu 3} 3.6 5.6"
    [ 256, [ 0, 64, ( true, [ "0@6" ] ); 64, 96, ( false, [ "3@6" ] ); 160, 96, ( false, [ "5@6" ] ) ] ];
  check_music "a grace note takes no time" ":4 3.1{gr} 5.1"
    [ 96, [ 0, 0, ( true, [ "3@1" ] ); 0, 96, ( false, [ "5@1" ] ) ] ];
  check_failure "a rhythm effect on a chord member cannot change its length"
    ":4 (3.1{d} 2.2)" (Unsupported_rhythm "d");
  check_failure "a tuplet the ticks cannot divide" ":4 0.6{tu 5} 3.6"
    (Unsupported_rhythm "tu 5");
  check_failure "a tuplet with no number" ":4 0.6{tu} 3.6" (Unsupported_rhythm "tu");
  check_failure "a dot and a tuplet together" ":4 0.6{d tu 3} 3.6"
    (Unsupported_rhythm "d tu 3");
  check_failure "another tuplet the ticks cannot divide" ":4 0.6{tu 6} 3.6"
    (Unsupported_rhythm "tu 6")

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
  check_failure "a close with hex for a count" ":4 0.6 \\rc 0x2" (Missing_argument Repeat_count);
  check_failure "a close with a signed count" ":4 0.6 \\rc -1" (Missing_argument Repeat_count);
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
  check_failure "an opener and nothing else" "\\ro" Repeat_without_bar;
  check_failure "a closer and nothing else" "\\rc 2" Repeat_without_bar;
  check_failure "endings and nothing else" "\\ae 1" Repeat_without_bar;
  check_failure "an opener after the last bar" ":4 0.6 | \\ro" Repeat_without_bar;
  check_failure "a closer after the last bar" ":4 0.6 | \\rc 2" Repeat_without_bar;
  check_failure "endings after the last bar" ":4 0.6 | \\ae 1" Repeat_without_bar;
  check_failure "an opener on an empty bar" "\\ro | :4 0.6" Repeat_without_bar;
  check_failure "a closer on an empty bar" ":4 0.6 | \\rc 2 | 3.6" Repeat_without_bar;
  check_failure "endings on an empty bar" "\\ae 1 | :4 0.6" Repeat_without_bar

(* A failure's sentence quotes the author's text and is printed on the pane,
   so whatever the text held, the sentence holds nothing a terminal acts on:
   no C0 byte or DEL, no C1 control in UTF-8 (an xterm reads U+009B as CSI),
   and no bidi control that reorders what the reader sees. *)
let acts_on_a_terminal text =
  let length = String.length text in
  let at index = Char.code text.[index] in
  let rec scan index =
    index < length
    && (at index < 0x20
        || at index = 0x7f
        || (at index = 0xc2 && index + 1 < length && at (index + 1) >= 0x80
            && at (index + 1) <= 0x9f)
        || (at index = 0xe2 && index + 2 < length && at (index + 1) = 0x80
            && at (index + 2) >= 0xaa && at (index + 2) <= 0xae)
        || (at index = 0xe2 && index + 2 < length && at (index + 1) = 0x81
            && at (index + 2) >= 0xa6 && at (index + 2) <= 0xa9)
        || scan (index + 1))
  in
  scan 0

let test_a_failure_sentence_holds_no_control_bytes () =
  let refuse sentence =
    Alcotest.(check bool)
      (Printf.sprintf "nothing a terminal acts on in %S" sentence)
      false
      (acts_on_a_terminal sentence)
  in
  List.iter
    (fun source ->
      match Score.read source with
      | Ok _ -> Alcotest.failf "%S was read as a score" source
      | Error failure -> refuse (Score.failure_text failure))
    [ ":4 3.1 \027[2Jboom"; ":4\027 0.6"; ":4 0.6{tu \0273}"; ":4 0.6 a\127b"
    ; ":4 0.6 a\xc2\x9bb"; ":4 0.6 a\xe2\x80\xaeb" ];
  List.iter
    (fun word -> refuse (Score.failure_text (Score.Not_a_note word)))
    [ "a\000b"; "a\x01b"; "a\x7fb"; "a\nb"; "tab\there"; "a\xc2\x9bb"; "a\xe2\x80\xaeb"
    ; "a\xe2\x81\xa6b" ]

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
        ; Alcotest.test_case "a tie holds the note before it" `Quick
            test_a_tie_holds_the_note_before_it
        ; Alcotest.test_case "a Bass VI line with ties" `Quick test_a_bass_vi_line_with_ties
        ; Alcotest.test_case "markup marks the note and keeps it" `Quick
            test_markup_marks_the_note_and_keeps_it
        ; Alcotest.test_case "what is read and not played" `Quick
            test_what_is_read_and_not_played
        ; Alcotest.test_case "the tuning names the lines" `Quick
            test_the_tuning_names_the_lines
        ; Alcotest.test_case "the documented bass score" `Quick test_documented_bass_score
        ; Alcotest.test_case "standalone instrument keeps Bass VI music" `Quick
            test_standalone_instrument_keeps_bass_vi_music
        ; Alcotest.test_case "parenthesized tuning members are checked" `Quick
            test_parenthesized_tuning_members_are_checked
        ; Alcotest.test_case "single-part metadata keeps music" `Quick
            test_single_part_metadata_keeps_music
        ; Alcotest.test_case "multiple parts are not flattened" `Quick
            test_multiple_parts_are_not_flattened
        ; Alcotest.test_case "instrument and staff do not guess" `Quick
            test_instrument_and_staff_do_not_guess
        ; Alcotest.test_case "metadata arguments and bar boundaries" `Quick
            test_metadata_arguments_and_bar_boundaries
        ] )
    ; ( "repeats"
      , [ Alcotest.test_case "a repeat opens and closes" `Quick
            test_a_repeat_opens_and_closes
        ; Alcotest.test_case "a second close says the count again" `Quick
            test_a_second_close_says_the_count_again
        ; Alcotest.test_case "endings gather across the bar" `Quick
            test_endings_gather_across_the_bar
        ; Alcotest.test_case "endings read alphaTab's parenthesized form" `Quick
            test_endings_read_alphaTabs_parenthesized_form
        ; Alcotest.test_case "endings stop where music resumes" `Quick
            test_endings_stop_where_music_resumes
        ; Alcotest.test_case "all marks on one bar" `Quick test_all_marks_on_one_bar
        ; Alcotest.test_case "counts at their edges" `Quick test_counts_at_their_edges
        ] )
    ; ( "the pane"
      , [ Alcotest.test_case "a drawn tab stays inside the pane" `Quick
            test_a_drawn_tab_stays_inside_the_pane
        ; Alcotest.test_case "a measure the pane cannot hold" `Quick
            test_a_measure_the_pane_cannot_hold
        ; Alcotest.test_case "wide note text does not overwrite the next beat" `Quick
            test_wide_note_text_does_not_overwrite_the_next_beat
        ; Alcotest.test_case "a repeated tab stays inside the pane" `Quick
            test_a_repeated_tab_stays_inside_the_pane
        ; Alcotest.test_case "a repeated measure the pane cannot hold" `Quick
            test_a_repeated_measure_the_pane_cannot_hold
        ; Alcotest.test_case "the rhythm line names each beat" `Quick
            test_the_rhythm_line_names_each_beat
        ; Alcotest.test_case "the rhythm line without the word is not there" `Quick
            test_the_rhythm_line_without_the_word_is_not_there
        ; Alcotest.test_case "the rhythm line fills between beats" `Quick
            test_the_rhythm_line_fills_between_beats
        ; Alcotest.test_case "directives are kept on the score" `Quick
            test_directives_are_kept
        ; Alcotest.test_case "directives absent are none" `Quick
            test_directives_absent_are_none
        ; Alcotest.test_case "the header line is drawn" `Quick
            test_header_line_drawn
        ; Alcotest.test_case "a non-ascii title shows as written" `Quick
            test_header_line_keeps_a_non_ascii_title
        ; Alcotest.test_case "the subtitle is kept with its bytes" `Quick
            test_subtitle_is_kept
        ; Alcotest.test_case "the last subtitle wins" `Quick
            test_last_subtitle_wins
        ; Alcotest.test_case "no header line without directives" `Quick
            test_header_line_absent_when_no_directives
        ; Alcotest.test_case "measure numbers climb with the measures" `Quick
            test_measure_numbers_climb_with_the_measures
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
