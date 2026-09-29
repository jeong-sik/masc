(* MASC's candle laid out as a screen body: the startup splash and /about
   both draw these rows, so what is checked here is what both screens show. *)

open Alcotest
module Screen = Masc_tui_emblem_screen
module View = Masc_tui_portrait_view
module Draw = Keeper_portrait_draw
module Layout = Masc_tui_message_layout
module Palette = Masc_tui_terminal_palette

(* Whether a row draws a half block, U+2580 or U+2584 (E2 96 80 / E2 96 84).
   A colour escape is ASCII, so it never looks like one. *)
let has_block row =
  let length = String.length row in
  let rec scan index =
    index + 2 < length
    && ((row.[index] = '\xe2' && row.[index + 1] = '\x96'
         && (row.[index + 2] = '\x80' || row.[index + 2] = '\x84'))
        || scan (index + 1))
  in
  scan 0

let caption = [ "first caption"; "second caption" ]
let cols = 80
let rows = 24
let origin = (3, 2)
let pixels = View.Pixels { cell_width = 10; cell_height = 20 }
let project = Palette.For_testing.best_color_for_level ~level:Palette.True_color

let laid_out ?(screen = Screen.About) ?(rows = rows) ?(elapsed = 0.0) display =
  Screen.rows ~screen ~cols ~rows ~caption ~elapsed ~display ~project ~origin

(* The rows the picture can have: the space less the caption and its gap. *)
let picture_rows_in rows = rows - List.length caption - 1
let picture_rows = picture_rows_in rows

(* A terminal tall enough that the startup cap, not the space, decides. *)
let tall_rows = 60

let index_of row lines =
  let rec find index = function
    | [] -> None
    | line :: rest -> if String.equal line row then Some index else find (index + 1) rest
  in
  find 0 lines

let trimmed line = String.trim (Masc_tui_theme.strip_sgr line)

let test_the_candle_stands_centred_over_its_caption screen () =
  let out = laid_out ~screen View.Mosaic in
  check bool "drawn" true (out.Screen.drawn = Screen.Moving);
  check bool "a mosaic is in the rows, nothing is placed" true
    (Option.is_none out.Screen.placement);
  let lines = out.Screen.lines in
  check bool "no taller than the space" true (List.length lines <= rows);
  List.iter
    (fun line ->
      check bool "no row wider than the space" true (Layout.display_width line <= cols))
    lines;
  let picture = List.filter has_block lines in
  check bool "the candle is drawn" true (picture <> []);
  let texts = List.map trimmed lines in
  let first_caption = Option.get (index_of "first caption" texts) in
  check (option int) "the second caption line follows the first"
    (Some (first_caption + 1)) (index_of "second caption" texts);
  check string "one blank row between the candle and its caption" ""
    (List.nth lines (first_caption - 1));
  check bool "the row above the gap is the candle's" false
    (String.equal (List.nth lines (first_caption - 2)) "");
  check bool "the candle is above its caption" true
    (List.exists has_block (List.filteri (fun index _ -> index < first_caption) lines));
  (* Centred top to bottom: the rows left above the block and below it differ
     by at most the one an odd remainder leaves. *)
  let rec leading_empty = function
    | "" :: rest -> 1 + leading_empty rest
    | _ -> 0
  in
  let above = leading_empty lines in
  let below = rows - (first_caption + 2) in
  check bool "centred top to bottom" true (abs (above - below) <= 1);
  (* Centred left to right: each row of the picture is its box behind a pad
     of plain spaces, and the pad leaves as much on the left as on the right. *)
  let max_rows =
    match screen with
    | Screen.Startup -> Int.min Screen.startup_picture_rows picture_rows
    | Screen.About -> picture_rows
  in
  let box = Option.get (View.fit View.Mosaic ~max_cols:cols ~max_rows) in
  let left = (cols - box.View.cols) / 2 in
  check int "every picture row is drawn" box.View.rows
    (List.length (List.filteri (fun index _ -> index >= above && index < above + box.View.rows) lines));
  List.iteri
    (fun index line ->
      if index >= above && index < above + box.View.rows then begin
        check string "padded with plain spaces" (String.make left ' ') (String.sub line 0 left);
        check int "the box's width behind the pad" (left + box.View.cols)
          (Layout.display_width line)
      end)
    lines;
  check bool "centred left to right" true (abs (left - (cols - left - box.View.cols)) <= 1)

let test_pixels_leave_blank_rows_and_place_the_picture_there () =
  let out = laid_out pixels in
  check bool "drawn" true (out.Screen.drawn = Screen.Moving);
  let p = Option.get out.Screen.placement in
  let origin_row, origin_col = origin in
  let top = p.View.row - origin_row in
  let left = p.View.column - origin_col in
  check int "the mascot's picture slot" (Masc_tui_graphics.image_id Masc_tui_graphics.Mascot)
    p.View.image_id;
  check bool "placed inside the body" true (top >= 0 && top + p.View.box.View.rows <= rows);
  check int "centred left to right" left ((cols - p.View.box.View.cols) / 2);
  List.iteri
    (fun index line ->
      if index >= top && index < top + p.View.box.View.rows then
        check string "the rows under the picture are blank"
          (String.make (left + p.View.box.View.cols) ' ') line)
    out.Screen.lines;
  check bool "no half blocks under real pixels" false (List.exists has_block out.Screen.lines);
  let texts = List.map trimmed out.Screen.lines in
  check (option int) "the caption sits one row under the picture"
    (Some (top + p.View.box.View.rows + 1)) (index_of "first caption" texts)

let test_no_picture_draws_the_caption_alone () =
  let alone display ~rows =
    let out = laid_out ~rows display in
    check bool "no candle" true (out.Screen.drawn = Screen.Absent);
    check bool "nothing placed" true (Option.is_none out.Screen.placement);
    check bool "no half blocks" false (List.exists has_block out.Screen.lines);
    check bool "the caption is still there" true
      (List.exists (fun line -> String.equal (trimmed line) "first caption") out.Screen.lines)
  in
  (* NO_COLOR, or a stdout that projects no colour. *)
  alone View.No_picture ~rows;
  (* A space smaller than a readable picture. *)
  alone View.Mosaic ~rows:4;
  alone pixels ~rows:4

let test_the_startup_candle_stays_small () =
  let block_rows screen =
    List.length (List.filter has_block (laid_out ~screen ~rows:tall_rows View.Mosaic).Screen.lines)
  in
  check bool "the splash still draws a mosaic candle" true (block_rows Screen.Startup > 0);
  check bool "no taller than the startup rows" true
    (block_rows Screen.Startup <= Screen.startup_picture_rows);
  check bool "/about lets it take the space" true
    (block_rows Screen.About > Screen.startup_picture_rows);
  let placed_rows screen ~rows =
    (Option.get (laid_out ~screen ~rows pixels).Screen.placement).View.box.View.rows
  in
  check int "placed pixels stop at the startup rows" Screen.startup_picture_rows
    (placed_rows Screen.Startup ~rows:tall_rows);
  check bool "/about places a taller picture" true
    (placed_rows Screen.About ~rows:tall_rows > Screen.startup_picture_rows);
  (* The cap only lowers the ceiling: a space under it keeps its own size. *)
  let short_rows = 12 in
  check int "a short space is not stretched to the startup rows"
    (placed_rows Screen.About ~rows:short_rows)
    (placed_rows Screen.Startup ~rows:short_rows);
  check bool "the short space is under the startup rows" true
    (picture_rows_in short_rows < Screen.startup_picture_rows)

let test_elapsed_time_is_the_pose () =
  let body, equipment = Keeper_portrait_look.mascot in
  let image_at elapsed = (Option.get (laid_out ~elapsed pixels).Screen.placement).View.image in
  let size = (Option.get (View.fit pixels ~max_cols:cols ~max_rows:picture_rows)).View.size in
  let drawn pose = Draw.render_posed body equipment pose size in
  check bool "the pose at the elapsed time" true
    (image_at 1.5 = drawn (Draw.pose_at ~milliseconds:1500));
  check bool "before the start is the start" true
    (image_at (-1.0) = drawn (Draw.pose_at ~milliseconds:0));
  check bool "a time that is not finite holds it still" true
    (image_at Float.nan = drawn Draw.still)

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
  View.set_display View.Mosaic;
  Screen.begin_frame ();
  check bool "a new frame has drawn no candle" true (Screen.drawn () = Screen.Absent);
  ignore (Screen.body ~screen:Screen.About ~cols ~rows:4 ~caption ~elapsed:0.0 ~origin);
  check bool "a frame too small for the candle records none" true
    (Screen.drawn () = Screen.Absent);
  ignore (Screen.body ~screen:Screen.About ~cols ~rows ~caption ~elapsed:0.0 ~origin);
  check bool "a frame that drew it records it" true (Screen.drawn () = Screen.Moving);
  Screen.begin_frame ();
  check bool "the next frame starts empty again" true (Screen.drawn () = Screen.Absent);
  View.set_display View.No_picture

(* Nothing of ours on the terminal: an empty frame flushed, its deletes
   thrown away. *)
let retire () =
  View.begin_frame ();
  View.flush ~rewritten:(fun _ -> false) ~write:ignore

let test_a_body_asks_for_its_picture () =
  View.set_display pixels;
  retire ();
  ignore (Screen.body ~screen:Screen.About ~cols ~rows ~caption ~elapsed:0.0 ~origin);
  let written = Buffer.create 4096 in
  View.flush ~rewritten:(fun _ -> false) ~write:(Buffer.add_string written);
  let bytes = Buffer.contents written in
  let expected = Option.get (laid_out pixels).Screen.placement in
  check string "the laid-out placement, and only it, is sent"
    (View.placement_bytes expected) bytes;
  retire ();
  View.set_display View.No_picture

let () =
  run "tui_emblem_screen"
    [ ( "layout"
      , [ test_case "the candle stands centred over its caption on /about" `Quick
            (test_the_candle_stands_centred_over_its_caption Screen.About)
        ; test_case "the candle stands centred over its caption on the splash" `Quick
            (test_the_candle_stands_centred_over_its_caption Screen.Startup)
        ; test_case "the startup candle stays small" `Quick
            test_the_startup_candle_stays_small
        ; test_case "pixels leave blank rows and place the picture there" `Quick
            test_pixels_leave_blank_rows_and_place_the_picture_there
        ; test_case "no picture draws the caption alone" `Quick
            test_no_picture_draws_the_caption_alone
        ] )
    ; ( "motion"
      , [ test_case "elapsed time is the pose" `Quick test_elapsed_time_is_the_pose
        ; test_case "a frame records only what it drew" `Quick
            test_a_frame_records_only_what_it_drew
        ; test_case "a body asks for its picture" `Quick test_a_body_asks_for_its_picture
        ] )
    ; ( "about"
      , [ test_case "it says only what was read" `Quick
            test_about_says_only_what_was_read
        ] )
    ]
