(** Test suite for Masc_tui_image_mosaic *)

open Alcotest
open Masc_tui_image_mosaic

let contains ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec loop i = i + lsub <= ls && (String.sub s i lsub = sub || loop (i + 1)) in
  loop 0

let rgb_of ints = String.init (List.length ints) (fun i -> Char.chr (List.nth ints i))

let test_two_by_two () =
  (* row-major: (0,0) red, (1,0) green, (0,1) blue, (1,1) white *)
  let rgb = rgb_of [ 255; 0; 0; 0; 255; 0; 0; 0; 255; 255; 255; 255 ] in
  let lines = render ~cols:2 ~rows:2 rgb in
  check int "rows/2 lines" 1 (List.length lines);
  let l = List.hd lines in
  check bool "cell0 fg = top red" true (contains ~sub:"38;2;255;0;0" l);
  check bool "cell0 bg = bottom blue" true (contains ~sub:"48;2;0;0;255" l);
  check bool "cell1 fg = top green" true (contains ~sub:"38;2;0;255;0" l);
  check bool "cell1 bg = bottom white" true (contains ~sub:"48;2;255;255;255" l);
  check bool "half-block glyph present" true (contains ~sub:"\xe2\x96\x80" l);
  check bool "line ends with reset" true (contains ~sub:"\027[0m" l)

let test_odd_rows_empty () =
  check (list string) "odd rows -> []" []
    (render ~cols:2 ~rows:3 (String.make 18 '\000'))

let test_short_buffer_empty () =
  check (list string) "short buffer -> []" []
    (render ~cols:4 ~rows:4 (String.make 5 '\000'))

let test_line_count_scales () =
  (* 8 rows -> 4 lines *)
  check int "8 rows -> 4 lines" 4
    (List.length (render ~cols:3 ~rows:8 (String.make (3 * 8 * 3) '\000')))

(* The server's MSX frame is 256x192, and the terminal is whatever it is. *)
let msx_w = 256
let msx_h = 192

let ratio (cols, rows) = float_of_int cols /. float_of_int rows
let msx_ratio = float_of_int msx_w /. float_of_int msx_h

(* A grid off by one pixel row is what evening the row count costs; a grid that
   ignored the ratio would be out by a third at this terminal size. *)
let close_to_msx_ratio label grid =
  let off = Float.abs (ratio grid -. msx_ratio) in
  let cols, rows = grid in
  if off > 0.05 then
    failf "%s: %dx%d is %.3f, and the frame is %.3f" label cols rows (ratio grid)
      msx_ratio

let test_a_wide_window_pillarboxes () =
  (* 100 columns of a 30-row window: the height binds, so the picture does not
     fill the width. Before, the grid was the window's own 100x56. *)
  let ((cols, rows) as grid) = fit_grid ~src_w:msx_w ~src_h:msx_h ~max_cols:100 ~max_rows:56 in
  close_to_msx_ratio "a 100x56 window" grid;
  check bool "inside the window" true (cols <= 100 && rows <= 56);
  check int "rows stack in pairs" 0 (rows land 1)

let test_a_tall_window_letterboxes () =
  let ((cols, rows) as grid) = fit_grid ~src_w:msx_w ~src_h:msx_h ~max_cols:64 ~max_rows:200 in
  close_to_msx_ratio "a 64x200 window" grid;
  check bool "inside the window" true (cols <= 64 && rows <= 200);
  check int "rows stack in pairs" 0 (rows land 1)

let test_no_room_draws_nothing () =
  check (pair int int) "one row is not a grid" (0, 0)
    (fit_grid ~src_w:msx_w ~src_h:msx_h ~max_cols:80 ~max_rows:1)

let rgb_of pixels =
  String.concat "" (List.map (fun (r, g, b) ->
    Printf.sprintf "%c%c%c" (Char.chr r) (Char.chr g) (Char.chr b)) pixels)

let pixel_at rgb i =
  ( Char.code rgb.[i * 3], Char.code rgb.[(i * 3) + 1], Char.code rgb.[(i * 3) + 2] )

let test_a_cell_is_the_mean_of_what_it_covers () =
  (* Four corners into one pixel: the answer is their average, and no corner
     can produce it alone. *)
  let src = rgb_of [ (0, 0, 0); (100, 100, 100); (200, 200, 200); (255, 255, 255) ] in
  let out = downscale ~src_w:2 ~src_h:2 ~cols:1 ~rows:1 src in
  check (triple int int int) "the mean of four" (138, 138, 138) (pixel_at out 0)

let test_a_thin_line_survives_the_shrink () =
  (* One white column in four black ones. Point sampling took column 0 and
     drew black -- the line was gone. Averaging leaves a quarter of it. *)
  let black = (0, 0, 0) and white = (255, 255, 255) in
  let src = rgb_of [ black; black; white; black ] in
  let out = downscale ~src_w:4 ~src_h:1 ~cols:1 ~rows:1 src in
  let r, _, _ = pixel_at out 0 in
  check bool "the line reaches the cell" true (r > 0);
  check (triple int int int) "a quarter of white" (63, 63, 63) (pixel_at out 0)

let test_a_short_frame_draws_nothing () =
  check string "one byte short" ""
    (downscale ~src_w:2 ~src_h:2 ~cols:1 ~rows:1 (String.make 11 '\000'))

let test_the_same_frame_gives_the_same_bytes () =
  let src = String.init (8 * 8 * 3) (fun i -> Char.chr (i mod 256)) in
  let once = downscale ~src_w:8 ~src_h:8 ~cols:3 ~rows:2 src in
  let twice = downscale ~src_w:8 ~src_h:8 ~cols:3 ~rows:2 src in
  check string "same source, same bytes" once twice

let test_a_grid_wider_than_the_source_still_draws () =
  (* Growing rather than shrinking: every cell covers at least one pixel, so
     no cell is left with nothing to average. *)
  let src = rgb_of [ (10, 20, 30); (40, 50, 60) ] in
  let out = downscale ~src_w:2 ~src_h:1 ~cols:4 ~rows:1 src in
  check int "one pixel per cell" (4 * 3) (String.length out);
  check (triple int int int) "first cell" (10, 20, 30) (pixel_at out 0);
  check (triple int int int) "last cell" (40, 50, 60) (pixel_at out 3)

let () =
  run "tui image mosaic"
    [ ( "fit_grid"
      , [ test_case "a wide window pillarboxes" `Quick test_a_wide_window_pillarboxes
        ; test_case "a tall window letterboxes" `Quick test_a_tall_window_letterboxes
        ; test_case "no room draws nothing" `Quick test_no_room_draws_nothing
        ] )
    ; ( "downscale"
      , [ test_case "a cell is the mean of what it covers" `Quick
            test_a_cell_is_the_mean_of_what_it_covers
        ; test_case "a thin line survives the shrink" `Quick
            test_a_thin_line_survives_the_shrink
        ; test_case "a short frame draws nothing" `Quick test_a_short_frame_draws_nothing
        ; test_case "the same frame gives the same bytes" `Quick
            test_the_same_frame_gives_the_same_bytes
        ; test_case "a grid wider than the source still draws" `Quick
            test_a_grid_wider_than_the_source_still_draws
        ] )
    ; ( "render"
      , [ test_case "2x2 half-block colours" `Quick test_two_by_two
        ; test_case "odd rows empty" `Quick test_odd_rows_empty
        ; test_case "short buffer empty" `Quick test_short_buffer_empty
        ; test_case "line count scales" `Quick test_line_count_scales
        ] )
    ]
