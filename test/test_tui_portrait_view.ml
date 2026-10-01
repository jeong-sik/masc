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

let test_lines_fill_the_box () =
  let pixels = View.Pixels { cell_width = 10; cell_height = 20 } in
  let box = Option.get (View.fit pixels ~max_cols:60 ~max_rows:8) in
  let lines = View.lines ~project pixels box (mascot box.View.size) in
  check (list string) "blank rows the picture is placed over"
    (List.init box.View.rows (fun _ -> String.make box.View.cols ' '))
    lines;
  let box = Option.get (View.fit View.Mosaic ~max_cols:40 ~max_rows:12) in
  let lines = View.lines ~project View.Mosaic box (mascot box.View.size) in
  check int "a mosaic row per box row" box.View.rows (List.length lines);
  List.iter
    (fun line -> check int "a mosaic row is the box wide" box.View.cols (Layout.display_width line))
    lines;
  check (list string) "no picture, no rows" []
    (View.lines ~project View.No_picture box (mascot box.View.size))

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

let () =
  run "tui_portrait_view"
    [ ( "display"
      , [ test_case "colour off draws no picture" `Quick test_colour_off_draws_no_picture ] )
    ; ( "fit"
      , [ test_case "pixels fit a square in cells" `Quick test_pixels_fit_a_square_in_cells
        ; test_case "a mosaic is one pixel per cell across" `Quick
            test_a_mosaic_is_one_pixel_per_cell_across
        ; test_case "lines fill the box" `Quick test_lines_fill_the_box
        ] )
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
        ] )
    ]
