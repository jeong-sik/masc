(* A candle portrait on the terminal: which of the three ways a terminal
   gets, how big a picture a space holds, and which bytes place and delete a
   picture after a frame. *)

open Alcotest
module View = Masc_tui_portrait_view
module Presenter = Masc_tui_frame_presenter
module Draw = Keeper_portrait_draw
module Layout = Masc_tui_message_layout
module Palette = Masc_tui_terminal_palette

let mascot_id = Masc_tui_graphics.image_id Masc_tui_graphics.Mascot

let project = Palette.For_testing.best_color_for_level ~level:Palette.True_color

let contains ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec loop i = i + lsub <= ls && (String.sub s i lsub = sub || loop (i + 1)) in
  loop 0

let display_name = function
  | View.Pixels { cell_width; cell_height } -> Printf.sprintf "pixels %dx%d" cell_width cell_height
  | View.Mosaic -> "mosaic"
  | View.No_picture -> "no picture"

let display = testable (fun ppf d -> Format.pp_print_string ppf (display_name d)) ( = )

let test_colour_off_draws_no_picture () =
  let chosen ~kitty ~cell_pixels ~colors_enabled ~projects_colour =
    View.display_of ~kitty ~cell_pixels ~colors_enabled ~projects_colour
  in
  check display "NO_COLOR wins over graphics" View.No_picture
    (chosen ~kitty:true ~cell_pixels:(Some (9, 18)) ~colors_enabled:false ~projects_colour:true);
  check display "graphics draw real pixels at the reported cell"
    (View.Pixels { cell_width = 9; cell_height = 18 })
    (chosen ~kitty:true ~cell_pixels:(Some (9, 18)) ~colors_enabled:true ~projects_colour:false);
  (* A box counted in cells from a guessed size lands beside the text. *)
  check display "graphics with an unreported cell draw the mosaic" View.Mosaic
    (chosen ~kitty:true ~cell_pixels:None ~colors_enabled:true ~projects_colour:true);
  check display "a zero cell is not a cell" View.Mosaic
    (chosen ~kitty:true ~cell_pixels:(Some (0, 18)) ~colors_enabled:true ~projects_colour:true);
  check display "and without colour to project, nothing" View.No_picture
    (chosen ~kitty:true ~cell_pixels:None ~colors_enabled:true ~projects_colour:false);
  check display "no graphics, colour: the mosaic" View.Mosaic
    (chosen ~kitty:false ~cell_pixels:None ~colors_enabled:true ~projects_colour:true);
  check display "no graphics, no colour to project: nothing" View.No_picture
    (chosen ~kitty:false ~cell_pixels:None ~colors_enabled:true ~projects_colour:false)

let test_pixels_fit_a_square_in_cells () =
  let pixels = View.Pixels { cell_width = 10; cell_height = 20 } in
  let box = Option.get (View.fit pixels ~max_cols:60 ~max_rows:12) in
  check int "as tall as the space" 12 box.View.rows;
  (* 12 rows of 20 px is 240 px tall; as many across is 24 cells of 10. *)
  check int "square across" 24 box.View.cols;
  check int "rendered at the cap, the terminal scales it" View.pixel_edge_cap
    (Draw.int_of_size box.View.size);
  let narrow = Option.get (View.fit pixels ~max_cols:12 ~max_rows:40) in
  check int "a narrow space bounds the height" 6 narrow.View.rows;
  check bool "never wider than the space" true (narrow.View.cols <= 12);
  check (option reject) "under the fewest readable rows, none" None
    (Option.map ignore (View.fit pixels ~max_cols:60 ~max_rows:(View.min_pixel_rows - 1)))

let test_a_mosaic_is_one_pixel_per_cell_across () =
  let box = Option.get (View.fit View.Mosaic ~max_cols:40 ~max_rows:12) in
  check int "two pixel rows per cell row" 12 box.View.rows;
  check int "one pixel per cell across" 24 box.View.cols;
  check int "the edge is the width" 24 (Draw.int_of_size box.View.size);
  let odd = Option.get (View.fit View.Mosaic ~max_cols:23 ~max_rows:40) in
  check int "an odd width is cut to even" 22 odd.View.cols;
  let wide = Option.get (View.fit View.Mosaic ~max_cols:400 ~max_rows:400) in
  check int "capped" View.mosaic_edge_cap wide.View.cols;
  check (option reject) "under the renderer's smallest edge, none" None
    (Option.map ignore (View.fit View.Mosaic ~max_cols:(Draw.min_size - 2) ~max_rows:40));
  check (option reject) "no picture fits nowhere" None
    (Option.map ignore (View.fit View.No_picture ~max_cols:400 ~max_rows:400))

let mascot size =
  let body, equipment = Keeper_portrait_look.mascot in
  Draw.render_posed body equipment Draw.still size

let placement ?(row = 4) ?(column = 7) size_rows =
  let pixels = View.Pixels { cell_width = 10; cell_height = 20 } in
  let box = Option.get (View.fit pixels ~max_cols:60 ~max_rows:size_rows) in
  { View.image_id = mascot_id; row; column; box; image = mascot box.View.size }

let test_placement_bytes_leave_the_cursor_where_it_was () =
  let p = placement 6 in
  let bytes = View.placement_bytes p in
  check bool "saves the cursor first" true (String.starts_with ~prefix:"\0277" bytes);
  check bool "restores it last" true (String.ends_with ~suffix:"\0278" bytes);
  check bool "moves to the 1-based corner" true (contains ~sub:"\027[5;8H" bytes);
  check bool "under the mascot's id" true
    (contains ~sub:(Printf.sprintf "i=%d," mascot_id) bytes);
  check bool "RGBA PNG" true (contains ~sub:"f=100," bytes);
  check bool "as many rows as the box" true
    (contains ~sub:(Printf.sprintf "r=%d," p.View.box.View.rows) bytes)

(* What the presenter did with the frame: cleared the screen and wrote every
   row, erased and wrote some rows, or wrote nothing. *)
let cleared = Presenter.Presented Presenter.Whole_screen
let rows_written rows = Presenter.Presented (Presenter.Rows rows)

let frame ?(presented = Presenter.Unchanged) requests =
  View.begin_frame ();
  List.iter View.request requests;
  let written = Buffer.create 4096 in
  View.flush presented ~write:(Buffer.add_string written);
  Buffer.contents written

let deleted = Masc_tui_graphics.delete_image ~image_id:mascot_id

let send_name = function
  | View.Keep -> "keep"
  | View.Put -> "put"
  | View.Transmit -> "transmit"

let send = testable (fun ppf s -> Format.pp_print_string ppf (send_name s)) ( = )

let test_send_follows_what_the_frame_did () =
  let p = placement 6 in
  let moved = { p with View.row = p.View.row + 1 } in
  let other = placement ~row:p.View.row 8 in
  check send "nothing under the id: transmit" View.Transmit
    (View.send Presenter.Unchanged ~shown:None p);
  check send "other pixels under the id: transmit" View.Transmit
    (View.send (rows_written []) ~shown:(Some other) p);
  check send "a clear screen took the pixels: transmit" View.Transmit
    (View.send cleared ~shown:(Some p) p);
  check send "a rewritten row crossed it: put" View.Put
    (View.send (rows_written [ p.View.row ]) ~shown:(Some p) p);
  check send "it moved: put" View.Put (View.send Presenter.Unchanged ~shown:(Some p) moved);
  check send "it moved while other rows were written: put" View.Put
    (View.send (rows_written [ 0 ]) ~shown:(Some p) moved);
  check send "rows it does not cross: keep" View.Keep
    (View.send (rows_written [ p.View.row - 1 ]) ~shown:(Some p) p);
  check send "nothing written: keep" View.Keep (View.send Presenter.Unchanged ~shown:(Some p) p)

let test_flush_sends_only_what_changed () =
  ignore (frame []);
  let p = placement 6 in
  check string "a new picture is transmitted" (View.placement_bytes p) (frame [ p ]);
  check string "the same picture on an unchanged frame is left alone" "" (frame [ p ]);
  check string "a clear screen took it, so it is transmitted again" (View.placement_bytes p)
    (frame ~presented:cleared [ p ]);
  let moved = { p with View.row = p.View.row + 1 } in
  check string "a moved picture is put where it now stands" (View.put_bytes moved)
    (frame [ moved ]);
  let changed = placement ~row:moved.View.row 8 in
  check string "a changed picture is transmitted" (View.placement_bytes changed)
    (frame [ changed ]);
  check string "a frame that no longer asks deletes it" deleted (frame []);
  check string "and then there is nothing to delete" "" (frame [])

(* A differential frame writes only the rows whose text changed. A picture
   those rows miss is left alone; one they cross is put back from the pixels
   the terminal holds, since a terminal that ties a placement to its cells
   loses the parts the text was written over. *)
let test_a_rewritten_row_puts_back_only_the_picture_it_crosses () =
  ignore (frame []);
  let p = placement 6 in
  let top = p.View.row and bottom = p.View.row + p.View.box.View.rows - 1 in
  ignore (frame [ p ]);
  check string "a row above the picture leaves it alone" ""
    (frame ~presented:(rows_written [ top - 1 ]) [ p ]);
  check string "a row below it leaves it alone" ""
    (frame ~presented:(rows_written [ bottom + 1 ]) [ p ]);
  check string "a frame that moved only the cursor leaves it alone" ""
    (frame ~presented:(rows_written []) [ p ]);
  check string "its top row puts it back" (View.put_bytes p)
    (frame ~presented:(rows_written [ top ]) [ p ]);
  check string "its bottom row puts it back" (View.put_bytes p)
    (frame ~presented:(rows_written [ bottom ]) [ p ]);
  ignore (frame [])

(* A running turn rewrites its progress row every motion step, and that row
   can sit beside the picture. No step may send the pixels again. *)
let test_a_row_rewritten_every_step_never_resends_the_pixels () =
  ignore (frame []);
  let p = placement 6 in
  ignore (frame [ p ]);
  let beside = p.View.row + 2 in
  for step = 1 to 20 do
    let written = frame ~presented:(rows_written [ beside ]) [ p ] in
    check string (Printf.sprintf "step %d puts the held pixels back" step) (View.put_bytes p) written;
    check bool (Printf.sprintf "step %d carries no PNG" step) false (contains ~sub:"f=100" written)
  done;
  check bool "a put names the held image" true
    (contains ~sub:(Printf.sprintf "a=p,i=%d," mascot_id) (View.put_bytes p));
  ignore (frame [])

let test_a_second_request_replaces_the_first () =
  ignore (frame []);
  let first = placement 6 and second = placement ~row:9 6 in
  check string "one picture per id, the last asked" (View.placement_bytes second)
    (frame [ first; second ]);
  ignore (frame [])

(* An evidence picture is a PNG file, placed by the same bookkeeping as a
   candle: transmitted when new or changed, put when moved, retransmitted
   after a clear screen, deleted when a frame stops asking. *)
let evidence_id = Masc_tui_graphics.image_id Masc_tui_graphics.Evidence_image_1

let png ?(row = 6) ?(column = 8) ?(rows = 10) ?crop ?(key = "key-a")
    ?(data = "png-file-bytes-a") () =
  { View.png_image_id = evidence_id; png_row = row; png_column = column; png_cols = 30
  ; png_rows = rows; png_crop = crop; png_key = key; png_data = data }

let frame_png ?(presented = Presenter.Unchanged) ?(held = []) pngs =
  View.begin_frame ();
  List.iter View.request_png pngs;
  List.iter (fun key -> View.hold_png ~image_id:evidence_id ~key) held;
  let written = Buffer.create 4096 in
  View.flush presented ~write:(Buffer.add_string written);
  Buffer.contents written

(* The view keeps one placement per image, under this id. *)
let only_placement = 1

let evidence_deleted = Masc_tui_graphics.delete_image ~image_id:evidence_id

let test_a_png_file_is_placed_kept_moved_and_deleted () =
  ignore (frame_png []);
  let p = png () in
  let first = frame_png [ p ] in
  check bool "a new picture is transmitted as a PNG file" true (contains ~sub:"f=100" first);
  check bool "under its slot's id" true (contains ~sub:(Printf.sprintf "i=%d," evidence_id) first);
  check bool "at the 1-based corner" true (contains ~sub:"\027[7;9H" first);
  check bool "as many rows as laid out" true (contains ~sub:"r=10," first);
  check string "the same picture on an unchanged frame is left alone" "" (frame_png [ p ]);
  check string "a clear screen took it, so it is transmitted again" first
    (frame_png ~presented:cleared [ p ]);
  let moved = png ~row:7 () in
  let put = frame_png [ moved ] in
  check bool "a moved picture is put" true (contains ~sub:"a=p," put);
  check bool "without its bytes" false (contains ~sub:"f=100" put);
  let changed = png ~row:7 ~key:"key-b" ~data:"png-file-bytes-b" () in
  check bool "a changed picture is transmitted" true
    (contains ~sub:"f=100" (frame_png [ changed ]));
  check string "a frame that no longer asks deletes it" evidence_deleted (frame_png []);
  check string "and then there is nothing to delete" "" (frame_png [])

(* The key is what stands for the bytes, so a 200 KB file is not compared on
   every frame; two files under one key are the same picture. *)
let test_a_png_file_is_compared_by_its_key () =
  ignore (frame_png []);
  ignore (frame_png [ png ~key:"same" ~data:"first bytes" () ]);
  check string "same key, same picture" ""
    (frame_png [ png ~key:"same" ~data:"other bytes" () ]);
  ignore (frame_png [])

let test_a_rewritten_row_puts_back_only_the_png_it_crosses () =
  ignore (frame_png []);
  let p = png () in
  let top = p.View.png_row and bottom = p.View.png_row + p.View.png_rows - 1 in
  ignore (frame_png [ p ]);
  check string "a row above leaves it alone" ""
    (frame_png ~presented:(rows_written [ top - 1 ]) [ p ]);
  check string "a row below leaves it alone" ""
    (frame_png ~presented:(rows_written [ bottom + 1 ]) [ p ]);
  check bool "its top row puts it back" true
    (contains ~sub:"a=p," (frame_png ~presented:(rows_written [ top ]) [ p ]));
  check bool "its bottom row puts it back" true
    (contains ~sub:"a=p," (frame_png ~presented:(rows_written [ bottom ]) [ p ]));
  ignore (frame_png [])

(* A candle and a PNG share the bookkeeping and nothing else: taking one
   down leaves the other where it is. *)
let test_a_png_and_a_candle_are_kept_apart () =
  ignore (frame []);
  let candle = placement 6 in
  View.begin_frame ();
  View.request candle;
  View.request_png (png ());
  let written = Buffer.create 4096 in
  View.flush Presenter.Unchanged ~write:(Buffer.add_string written);
  check bool "both were transmitted" true
    (contains ~sub:(Printf.sprintf "i=%d," mascot_id) (Buffer.contents written)
     && contains ~sub:(Printf.sprintf "i=%d," evidence_id) (Buffer.contents written));
  check string "dropping the PNG deletes only the PNG" evidence_deleted (frame [ candle ]);
  check string "dropping the candle deletes only the candle" deleted (frame []);
  check string "nothing left" "" (frame_png [])

(* A picture the window cuts is the same pixels in a smaller place: scrolling
   it is a put with the new rectangle, never a transfer. *)
let test_a_scrolled_png_is_put_with_its_new_crop () =
  ignore (frame_png []);
  let whole = png () in
  ignore (frame_png [ whole ]);
  let cut = png ~row:6 ~rows:6 ~crop:{ Masc_tui_graphics.top_px = 160; height_px = 240 } () in
  let put = frame_png [ cut ] in
  check bool "the pixels do not travel again" false (contains ~sub:"f=100" put);
  check bool "a put" true (contains ~sub:"a=p," put);
  check bool "of the new rectangle" true (contains ~sub:"y=160" put && contains ~sub:"h=240" put);
  check bool "over the rows that show" true (contains ~sub:"r=6," put);
  check string "the same crop on the next frame is left alone" "" (frame_png [ cut ]);
  let moved_crop = png ~row:6 ~rows:6 ~crop:{ Masc_tui_graphics.top_px = 200; height_px = 240 } () in
  let put_again = frame_png [ moved_crop ] in
  check bool "another rectangle in the same cells is a put too" true
    (contains ~sub:"a=p," put_again && contains ~sub:"y=200" put_again);
  ignore (frame_png [])

(* A picture wholly out of the window loses its placement and keeps its pixels
   while the view holds it, so scrolling back is a put. Without the hold, or
   with other bytes, the pixels are freed. *)
let test_a_held_png_keeps_its_pixels_without_a_placement () =
  ignore (frame_png []);
  let p = png () in
  let first = frame_png [ p ] in
  check bool "transmitted once" true (contains ~sub:"f=100" first);
  let hidden = frame_png ~held:[ "key-a" ] [] in
  check string "scrolled out: only the placement goes"
    (Masc_tui_graphics.delete_placement ~image_id:evidence_id ~placement_id:only_placement)
    hidden;
  check string "still held: nothing more is sent" "" (frame_png ~held:[ "key-a" ] []);
  let back = frame_png [ p ] in
  check bool "scrolled back: a put" true (contains ~sub:"a=p," back);
  check bool "no pixels travel" false (contains ~sub:"f=100" back);
  ignore (frame_png ~held:[ "key-a" ] []);
  check string "the view lets go: the pixels are freed" evidence_deleted (frame_png []);
  check string "and then there is nothing to delete" "" (frame_png [])

let test_a_hold_for_other_bytes_does_not_keep_these () =
  ignore (frame_png []);
  ignore (frame_png [ png () ]);
  check string "a hold under another key frees the pixels" evidence_deleted
    (frame_png ~held:[ "key-other" ] []);
  ignore (frame_png [])

let test_a_clear_screen_takes_held_pixels_too () =
  ignore (frame_png []);
  let p = png () in
  ignore (frame_png [ p ]);
  ignore (frame_png ~held:[ "key-a" ] []);
  let back = frame_png ~presented:cleared [ p ] in
  check bool "after a clear screen the return is a transfer" true (contains ~sub:"f=100" back);
  ignore (frame_png []);
  (* The clear came while the picture was placed and held in the same frame
     the screen was cleared: nothing remains to put back. *)
  ignore (frame_png [ p ]);
  ignore (frame_png ~presented:cleared ~held:[ "key-a" ] []);
  let again = frame_png [ p ] in
  check bool "held through a clear screen is not held" true (contains ~sub:"f=100" again);
  ignore (frame_png [])

let test_a_held_png_replaced_by_a_candle_id_is_not_confused () =
  (* A hold names an image id and a key; a candle under another id is not
     touched by it. *)
  ignore (frame []);
  let candle = placement 6 in
  ignore (frame [ candle ]);
  View.begin_frame ();
  View.hold_png ~image_id:evidence_id ~key:"key-a";
  View.request candle;
  let written = Buffer.create 64 in
  View.flush Presenter.Unchanged ~write:(Buffer.add_string written);
  check string "the candle stays and nothing is written" "" (Buffer.contents written);
  ignore (frame [])

let () =
  run "tui_portrait_view"
    [ ( "display"
      , [ test_case "colour off draws no picture" `Quick test_colour_off_draws_no_picture ] )
    ; ( "fit"
      , [ test_case "pixels fit a square in cells" `Quick test_pixels_fit_a_square_in_cells
        ; test_case "a mosaic is one pixel per cell across" `Quick
            test_a_mosaic_is_one_pixel_per_cell_across
        ;] )
    ; ( "placement"
      , [ test_case "placement bytes leave the cursor where it was" `Quick
            test_placement_bytes_leave_the_cursor_where_it_was
        ; test_case "send follows what the frame did" `Quick test_send_follows_what_the_frame_did
        ; test_case "flush sends only what changed" `Quick test_flush_sends_only_what_changed
        ; test_case "a rewritten row puts back only the picture it crosses" `Quick
            test_a_rewritten_row_puts_back_only_the_picture_it_crosses
        ; test_case "a row rewritten every step never resends the pixels" `Quick
            test_a_row_rewritten_every_step_never_resends_the_pixels
        ; test_case "a second request replaces the first" `Quick
            test_a_second_request_replaces_the_first
        ; test_case "a PNG file is placed, kept, moved and deleted" `Quick
            test_a_png_file_is_placed_kept_moved_and_deleted
        ; test_case "a PNG file is compared by its key" `Quick
            test_a_png_file_is_compared_by_its_key
        ; test_case "a rewritten row puts back only the PNG it crosses" `Quick
            test_a_rewritten_row_puts_back_only_the_png_it_crosses
        ; test_case "a PNG and a candle are kept apart" `Quick
            test_a_png_and_a_candle_are_kept_apart
        ; test_case "a scrolled PNG is put with its new crop" `Quick
            test_a_scrolled_png_is_put_with_its_new_crop
        ; test_case "a held PNG keeps its pixels without a placement" `Quick
            test_a_held_png_keeps_its_pixels_without_a_placement
        ; test_case "a hold for other bytes does not keep these" `Quick
            test_a_hold_for_other_bytes_does_not_keep_these
        ; test_case "a clear screen takes held pixels too" `Quick
            test_a_clear_screen_takes_held_pixels_too
        ; test_case "a hold leaves a candle alone" `Quick
            test_a_held_png_replaced_by_a_candle_id_is_not_confused
        ] )
    ]
