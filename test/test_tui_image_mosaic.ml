(** Test suite for Masc_tui_image_mosaic *)

open Alcotest
open Masc_tui_image_mosaic

let test_odd_rows_empty () =
  check (list string) "odd rows -> []" []
    (render ~cols:2 ~rows:3 (String.make 18 '\000'))

let test_short_buffer_empty () =
  check (list string) "short buffer -> []" []
    (render ~cols:4 ~rows:4 (String.make 5 '\000'))

let true_colour = Masc_tui_terminal_palette.For_testing.best_color_for_level
    ~level:Masc_tui_terminal_palette.True_color

let test_rgba_refuses_what_render_refuses () =
  check (list string) "odd rows" [] (render_rgba ~project:true_colour ~cols:1 ~rows:3 (String.make 12 '\000'));
  check (list string) "short buffer" [] (render_rgba ~project:true_colour ~cols:2 ~rows:2 (String.make 15 '\000'))

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
      , [] )
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
      , [ test_case "odd rows empty" `Quick test_odd_rows_empty
        ; test_case "short buffer empty" `Quick test_short_buffer_empty
        ;] )
    ; ( "render_rgba"
      , [ test_case "refuses what render refuses" `Quick test_rgba_refuses_what_render_refuses
        ] )
    ]
