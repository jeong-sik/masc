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

let () =
  run "tui image mosaic"
    [ ( "render"
      , [ test_case "2x2 half-block colours" `Quick test_two_by_two
        ; test_case "odd rows empty" `Quick test_odd_rows_empty
        ; test_case "short buffer empty" `Quick test_short_buffer_empty
        ; test_case "line count scales" `Quick test_line_count_scales
        ] )
    ]
