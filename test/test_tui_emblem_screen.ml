(* The /about candle laid out inside the available screen body. *)

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
let cell_height = 20
let pixels = View.Pixels { cell_width = 10; cell_height }
let project = Palette.For_testing.best_color_for_level ~level:Palette.True_color

let laid_out ?(style = Screen.Painted) ?(rows = rows) ?(elapsed = 0.0) display =
  Screen.rows ~style ~cols ~rows ~caption ~elapsed ~display ~project ~origin

(* The rows the picture can have: the space less the caption and its gap. *)
let picture_rows_in rows = rows - List.length caption - 1
let picture_rows = picture_rows_in rows

let index_of row lines =
  let rec find index = function
    | [] -> None
    | line :: rest -> if String.equal line row then Some index else find (index + 1) rest
  in
  find 0 lines

let trimmed line = String.trim (Masc_tui_theme.strip_sgr line)

let test_the_candle_stands_centred_over_its_caption () =
  let out = laid_out View.Mosaic in
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
  let box = Option.get (View.fit View.Mosaic ~max_cols:cols ~max_rows:picture_rows) in
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

let test_mosaic_uses_the_compact_candle () =
  let out = laid_out View.Mosaic in
  let box = Option.get (View.fit View.Mosaic ~max_cols:cols ~max_rows:picture_rows) in
  let body, equipment = Keeper_portrait_look.mascot in
  let image = Draw.render_compact_posed body equipment Draw.still box.View.size in
  let expected =
    View.lines ~project View.Mosaic box image
    |> List.map (fun line -> String.make ((cols - box.View.cols) / 2) ' ' ^ line)
  in
  let top = (rows - box.View.rows - List.length caption - 1) / 2 in
  let actual =
    List.filteri (fun index _ -> index >= top && index < top + box.View.rows) out.Screen.lines
  in
  check (list string) "the mosaic contains the compact candle" expected actual

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

(* The dotted candle is the solid mascot, drawn as many pixels tall as the
   terminal shows it, so the terminal never scales its dots. *)
let test_a_dotted_candle_is_drawn_at_the_size_it_is_shown () =
  let placed ~elapsed =
    Option.get (laid_out ~style:Screen.Dotted ~elapsed pixels).Screen.placement
  in
  let p = placed ~elapsed:1.5 in
  let shown = Option.get (Draw.size_of_int (p.View.box.View.rows * cell_height)) in
  check int "one pixel per pixel the terminal shows" (p.View.box.View.rows * cell_height)
    p.View.image.Draw.edge;
  check bool "the solid mascot at that moment of its sway" true
    (String.equal p.View.image.Draw.rgba
       (Keeper_portrait_solid.mascot ~milliseconds:1500 shown).Draw.rgba);
  check bool "not the painted candle" false
    (String.equal p.View.image.Draw.rgba (Option.get (laid_out pixels).Screen.placement).View.image.Draw.rgba);
  check bool "held still, it faces front" true
    (String.equal (placed ~elapsed:Float.nan).View.image.Draw.rgba
       (Keeper_portrait_solid.mascot ~milliseconds:0 shown).Draw.rgba);
  let mosaic = laid_out ~style:Screen.Dotted View.Mosaic in
  check bool "a mosaic draws it too" true (List.exists has_block mosaic.Screen.lines)

let test_the_style_is_stored_by_name () =
  List.iter
    (fun style ->
      check bool "round trip" true
        (Screen.style_of_string (Screen.string_of_style style) = Some style);
      check bool "the other one and back" true
        (Screen.next_style (Screen.next_style style) = style && Screen.next_style style <> style))
    [ Screen.Painted; Screen.Dotted ];
  check bool "an unknown name is none" true (Screen.style_of_string "sparkly" = None)

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
  ignore (Screen.body ~cols ~rows:4 ~caption ~elapsed:0.0 ~origin);
  check bool "a frame too small for the candle records none" true
    (Screen.drawn () = Screen.Absent);
  ignore (Screen.body ~cols ~rows ~caption ~elapsed:0.0 ~origin);
  check bool "a frame that drew it records it" true (Screen.drawn () = Screen.Moving);
  Screen.begin_frame ();
  check bool "the next frame starts empty again" true (Screen.drawn () = Screen.Absent);
  View.set_display View.No_picture

(* Nothing of ours on the terminal: an empty frame flushed, its deletes
   thrown away. *)
let retire () =
  View.begin_frame ();
  View.flush Masc_tui_frame_presenter.Unchanged ~write:(fun (_bytes : string) -> ())

let test_a_body_asks_for_its_picture () =
  View.set_display pixels;
  retire ();
  ignore (Screen.body ~cols ~rows ~caption ~elapsed:0.0 ~origin);
  let written = Buffer.create 4096 in
  View.flush Masc_tui_frame_presenter.Unchanged ~write:(Buffer.add_string written);
  let bytes = Buffer.contents written in
  let expected = Option.get (laid_out pixels).Screen.placement in
  check string "the laid-out placement, and only it, is sent"
    (View.placement_bytes expected) bytes;
  retire ();
  View.set_display View.No_picture

let about ~cols ~frame display =
  Screen.about_rows ~style:Screen.Painted ~cols ~rows:24 ~caption
    ~frame ~keepers:["fixture-alpha"; "fixture-bravo"; "fixture-charlie"; "fixture-delta"; "extra"]
    ~display ~project ~origin

let test_the_arrival_gathers_then_stops () =
  let at_start = about ~cols:76 ~frame:0 pixels in
  let gathered = about ~cols:76 ~frame:7 pixels in
  let finished = about ~cols:76 ~frame:Screen.final_frame pixels in
  check int "narrow view shows two registered Keepers" 2 at_start.Screen.visible_keepers;
  check bool "other registered Keepers have a count" true
    (List.exists (fun line -> String.equal (trimmed line) "+3 more Keepers")
       at_start.Screen.lines);
  check bool "the arrival is moving at first" true
    (at_start.Screen.drawn = Screen.Moving);
  check bool "the final frame is still" true
    (finished.Screen.drawn = Screen.Still);
  let positions frame =
    frame.Screen.placements
    |> List.filter (fun p ->
         p.View.image_id <> Masc_tui_graphics.image_id Masc_tui_graphics.Mascot)
    |> List.map (fun p -> p.View.column)
  in
  check bool "the Keepers gather beside the candle" true
    (positions at_start <> positions gathered);
  check (list int) "they disperse into the final roster" (positions at_start)
    (positions finished);
  check (list int) "every portrait has its own Kitty id"
    [41; 43; 44]
    (List.map (fun p -> p.View.image_id) at_start.Screen.placements
     |> List.sort Int.compare)

let test_wide_and_mosaic_keep_the_roster () =
  let wide = about ~cols:136 ~frame:Screen.final_frame View.Mosaic in
  check int "wide view shows four registered Keepers" 4 wide.Screen.visible_keepers;
  check bool "the fifth Keeper is counted" true
    (List.exists (fun line -> String.equal (trimmed line) "+1 more Keepers")
       wide.Screen.lines);
  check bool "mosaic draws portraits in text cells" true
    (List.exists has_block wide.Screen.lines);
  check bool "mosaic asks for no Kitty placement" true
    (wide.Screen.placements = []);
  List.iter
    (fun line ->
      check bool "no about row loses its edge" true
        (Layout.display_width line <= 136))
    wide.Screen.lines

let test_no_picture_keeps_the_count () =
  let plain = about ~cols:76 ~frame:Screen.final_frame View.No_picture in
  check bool "no picture asks for no animation tick" true
    (plain.Screen.drawn = Screen.Absent);
  check int "four Keeper names remain readable without colour" 4
    plain.Screen.visible_keepers;
  check bool "the remaining registered Keeper is counted" true
    (List.exists (fun line -> String.equal (trimmed line) "+1 more Keepers")
       plain.Screen.lines)

let test_every_arrival_frame_fits_its_terminal () =
  List.iter
    (fun cols ->
      List.iter
        (fun display ->
          for frame = 0 to Screen.final_frame do
            let scene = about ~cols ~frame display in
            List.iter
              (fun line ->
                check bool "arrival row fits without a cut" true
                  (Layout.display_width line <= cols))
              scene.Screen.lines;
            List.iter
              (fun placement ->
                check bool "Kitty picture stays inside its frame" true
                  (placement.View.column >= snd origin
                   && placement.View.column + placement.View.box.View.cols
                      <= snd origin + cols))
              scene.Screen.placements
          done)
        [pixels; View.Mosaic])
    [76; 136]

let test_about_candle_frames_are_reused_with_a_bound () =
  let mascot_image scene =
    scene.Screen.placements
    |> List.find (fun p ->
         p.View.image_id = Masc_tui_graphics.image_id Masc_tui_graphics.Mascot)
    |> fun placement -> placement.View.image
  in
  let first = mascot_image (about ~cols:76 ~frame:4 pixels) in
  ignore (about ~cols:76 ~frame:7 pixels);
  let repeated = mascot_image (about ~cols:76 ~frame:4 pixels) in
  check bool "returning to a candle frame reuses its image" true (first == repeated);
  List.iter
    (fun display ->
      List.iter
        (fun frame -> ignore (about ~cols:76 ~frame display))
        (List.init (Screen.final_frame + 1) Fun.id))
    [pixels; View.Mosaic];
  check bool "the frame cache stays at sixteen images" true
    (Screen.about_cached_frames () <= 16)

let () =
  run "tui_emblem_screen"
    [ ( "layout"
      , [ test_case "the candle stands centred over its caption on /about" `Quick
            test_the_candle_stands_centred_over_its_caption
        ; test_case "the mosaic uses the compact candle" `Quick
            test_mosaic_uses_the_compact_candle
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
        ; test_case "a dotted candle is drawn at the size it is shown" `Quick
            test_a_dotted_candle_is_drawn_at_the_size_it_is_shown
        ; test_case "the style is stored by name" `Quick test_the_style_is_stored_by_name
        ] )
    ; ( "about"
      , [ test_case "it says only what was read" `Quick
            test_about_says_only_what_was_read
        ; test_case "the arrival gathers then stops" `Quick
            test_the_arrival_gathers_then_stops
        ; test_case "wide mosaic keeps the roster" `Quick
            test_wide_and_mosaic_keep_the_roster
        ; test_case "no picture keeps the count" `Quick
            test_no_picture_keeps_the_count
        ; test_case "every arrival frame fits the terminal" `Quick
            test_every_arrival_frame_fits_its_terminal
        ; test_case "candle frames are reused within a bound" `Quick
            test_about_candle_frames_are_reused_with_a_bound
        ] )
    ]
