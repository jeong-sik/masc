(* The turning imp laid out as a screen body: the startup splash and /about
   both draw these rows, so what is checked here is what both screens show. *)

open Alcotest
module Screen = Masc_tui_emblem_screen
module Emblem = Masc_tui_imp_emblem
module Layout = Masc_tui_message_layout

(* Whether a row draws any Braille glyph. U+2800..U+28FF is E2 A0 80 through
   E2 A3 BF in UTF-8, and a colour escape is ASCII, so it never looks like one. *)
let has_braille row =
  let length = String.length row in
  let rec scan index =
    index + 2 < length
    && ((row.[index] = '\xe2' && row.[index + 1] >= '\xa0' && row.[index + 1] <= '\xa3')
        || scan (index + 1))
  in
  scan 0

let caption = [ "first caption"; "second caption" ]
let cols = 80
let rows = 24

let still_rows ?(elapsed = 0.0) () =
  Screen.rows ~cols ~rows ~caption ~elapsed ~colors_enabled:false
    ~backdrop:Emblem.Unknown

let index_of row lines =
  let rec find index = function
    | [] -> None
    | line :: rest -> if String.equal line row then Some index else find (index + 1) rest
  in
  find 0 lines

let trimmed line = String.trim line

let test_the_imp_stands_centred_over_its_caption () =
  let drawn, lines = still_rows () in
  check bool "held still without colour" true (drawn = Screen.Still);
  check bool "no taller than the space" true (List.length lines <= rows);
  List.iter
    (fun line ->
      check bool "no row wider than the space" true
        (Layout.display_width line <= cols))
    lines;
  let emblem = List.filter has_braille lines in
  check bool "the imp is drawn" true (emblem <> []);
  let texts = List.map trimmed lines in
  let first_caption = Option.get (index_of "first caption" texts) in
  check (option int) "the second caption line follows the first"
    (Some (first_caption + 1)) (index_of "second caption" texts);
  (* The gap is the one row written as nothing at all; every row of the imp's
     box is padded out, blank or not. *)
  check string "one blank row between the imp and its caption" ""
    (List.nth lines (first_caption - 1));
  check bool "the row above the gap is the imp's" false
    (String.equal (List.nth lines (first_caption - 2)) "");
  check bool "the imp is above its caption" true
    (List.exists has_braille (List.filteri (fun index _ -> index < first_caption) lines));
  (* Centred top to bottom: the rows left above the block and below it differ
     by at most the one an odd remainder leaves. *)
  let rec leading_empty = function
    | "" :: rest -> 1 + leading_empty rest
    | _ -> 0
  in
  let above = leading_empty lines in
  let below = rows - (first_caption + 2) in
  check bool "centred top to bottom" true (abs (above - below) <= 1);
  (* Centred left to right: each imp row is the emblem's box behind a pad,
     and the pad leaves as much to the left of the box as to its right. *)
  let box =
    Option.get
      (Emblem.fit ~cols ~rows:(rows - List.length caption - 1))
  in
  List.iter
    (fun line ->
      let width = Layout.display_width line in
      let left = width - box.Emblem.cols in
      let right = cols - width in
      check bool "centred left to right" true (abs (left - right) <= 1))
    emblem

let test_too_little_space_draws_the_caption_alone () =
  let drawn, lines =
    Screen.rows ~cols ~rows:4 ~caption ~elapsed:0.0 ~colors_enabled:true
      ~backdrop:(Emblem.Page Masc_tui_terminal_palette.Dark)
  in
  check bool "no imp" true (drawn = Screen.Absent);
  check bool "no Braille" false (List.exists has_braille lines);
  check bool "the caption is still there" true
    (List.exists (fun line -> String.equal (trimmed line) "first caption") lines)

let test_it_turns_only_with_colour_and_a_known_page () =
  let dark = Emblem.Page Masc_tui_terminal_palette.Dark in
  check bool "colour on a known page turns" true
    (Screen.moves ~colors_enabled:true dark);
  check bool "NO_COLOR holds it still" false
    (Screen.moves ~colors_enabled:false dark);
  check bool "an unknown page holds it still" false
    (Screen.moves ~colors_enabled:true Emblem.Unknown)

let test_elapsed_time_turns_the_imp () =
  let dark = Emblem.Page Masc_tui_terminal_palette.Dark in
  let at elapsed =
    Screen.rows ~cols ~rows ~caption ~elapsed ~colors_enabled:true ~backdrop:dark
  in
  let drawn, first = at 0.0 in
  check bool "drawn turning" true (drawn = Screen.Moving);
  let _, later = at 1.5 in
  check bool "a second and a half later the imp has turned" false (first = later);
  check bool "the same moment draws the same rows" true (first = snd (at 0.0));
  check bool "before the start is the start" true (first = snd (at (-1.0)));
  check bool "a time that is not finite holds the imp still" true
    (snd (at Float.nan) = snd (Screen.rows ~cols ~rows ~caption ~elapsed:0.0
                                 ~colors_enabled:false ~backdrop:dark));
  let _, still_first = still_rows ~elapsed:0.0 () in
  let _, still_later = still_rows ~elapsed:1.5 () in
  check bool "held still, time changes nothing" true (still_first = still_later)

let test_about_says_only_what_was_read () =
  check string "a read roster is counted"
    "Theme: dusk  \xc2\xb7  Keepers: 2"
    (Screen.about_facts ~theme:"dusk" (Screen.Keepers_read 2));
  check string "a read empty roster says zero"
    "Theme: dusk  \xc2\xb7  Keepers: 0"
    (Screen.about_facts ~theme:"dusk" (Screen.Keepers_read 0));
  (* No count is not a count of none (#35747). *)
  check string "an unreadable roster says so"
    "Theme: dusk  \xc2\xb7  Keepers: unavailable"
    (Screen.about_facts ~theme:"dusk" Screen.Keepers_unreadable);
  check string "an unread roster says not loaded"
    "Theme: dusk  \xc2\xb7  Keepers: not loaded"
    (Screen.about_facts ~theme:"dusk" Screen.Keepers_unread)

let test_a_frame_records_only_what_it_drew () =
  Screen.begin_frame ();
  check bool "a new frame has drawn no imp" true (Screen.drawn () = Screen.Absent);
  ignore (Screen.body ~cols ~rows:4 ~caption ~elapsed:0.0);
  check bool "a frame too small for the imp records none" true
    (Screen.drawn () = Screen.Absent);
  ignore (Screen.body ~cols ~rows ~caption ~elapsed:0.0);
  check bool "a frame that drew it records it" false (Screen.drawn () = Screen.Absent);
  Screen.begin_frame ();
  check bool "the next frame starts empty again" true (Screen.drawn () = Screen.Absent)

let () =
  run "tui_emblem_screen"
    [ ( "layout"
      , [ test_case "the imp stands centred over its caption" `Quick
            test_the_imp_stands_centred_over_its_caption
        ; test_case "too little space draws the caption alone" `Quick
            test_too_little_space_draws_the_caption_alone
        ] )
    ; ( "motion"
      , [ test_case "it turns only with colour and a known page" `Quick
            test_it_turns_only_with_colour_and_a_known_page
        ; test_case "elapsed time turns the imp" `Quick
            test_elapsed_time_turns_the_imp
        ; test_case "a frame records only what it drew" `Quick
            test_a_frame_records_only_what_it_drew
        ] )
    ; ( "about"
      , [ test_case "it says only what was read" `Quick
            test_about_says_only_what_was_read
        ] )
    ]
