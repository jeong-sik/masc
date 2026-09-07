(** The MSX spectator screen keeps the machine's shape and its strokes.

    Both cases here were regressions in the first version of this screen, and
    both are invisible to a type: the frame drew, it just drew wrong. *)

open Alcotest

module Msx = Masc_tui_msx
module Types = Masc_tui_types

(* A 256x192 frame of 8x8 glyph cells, each carrying one-pixel strokes at an
   offset that varies per cell -- the shape of MSX text, where a stroke sits
   wherever the glyph puts it rather than on a fixed grid. A regular stripe
   would not do: nearest-neighbour lands on a fixed column too and keeps a
   fixed pattern by luck, which says nothing about a page of text. *)
let stroked_frame () =
  let w = 256 and h = 192 in
  let rgb = Bytes.make (w * h * 3) '\000' in
  for y = 0 to h - 1 do
    for x = 0 to w - 1 do
      let cell_x = x / 8 and cell_y = y / 8 in
      let in_x = x mod 8 and in_y = y mod 8 in
      (* Two strokes per cell, placed by the cell's own coordinates. *)
      let stem = (cell_x + (3 * cell_y)) mod 7 in
      let bar = (cell_y + (5 * cell_x)) mod 7 in
      if in_x = stem || in_y = bar
      then (
        let i = ((y * w) + x) * 3 in
        Bytes.set rgb i '\255';
        Bytes.set rgb (i + 1) '\255';
        Bytes.set rgb (i + 2) '\255')
    done
  done;
  { Types.msx_number = 1
  ; msx_width = w
  ; msx_height = h
  ; msx_rgb = Bytes.to_string rgb
  ; msx_mode = "screen2"
  ; msx_cartridge = Some "test.rom"
  }
;;

let drawn frame =
  let buf = Buffer.create 4096 in
  Msx.render ~write:(Buffer.add_string buf) (Some frame);
  Buffer.contents buf
;;

(* Every foreground colour the mosaic emitted, as (r,g,b). *)
let foreground_colours out =
  let re = Str.regexp "\027\\[38;2;\\([0-9]+\\);\\([0-9]+\\);\\([0-9]+\\)m" in
  let rec scan acc pos =
    match Str.search_forward re out pos with
    | exception Not_found -> acc
    | at ->
      let g n = int_of_string (Str.matched_group n out) in
      scan ((g 1, g 2, g 3) :: acc) (at + 1)
  in
  scan [] 0
;;

(* A stroke every 8 source columns cannot survive a sampler that reads one
   pixel per cell: at the sizes this screen runs, the sample lands between
   strokes and the cell comes back black. Averaging the covered rectangle
   leaves every stroke a mark, dim where it is thin. Measured on a live
   pac-man.rom frame: nearest kept 11% of the grid lit and the average 23%. *)
let test_thin_strokes_survive_the_shrink () =
  let out = drawn (stroked_frame ()) in
  let colours = foreground_colours out in
  check bool "the frame drew at all" true (colours <> []);
  let lit = List.filter (fun (r, g, b) -> r + g + b > 24) colours in
  let ratio = float_of_int (List.length lit) /. float_of_int (List.length colours) in
  (* Measured on this fixture at the size the screen draws: averaging the
     covered rectangle leaves 90% of cells carrying some light, reading one
     pixel per cell leaves 24%. The strokes are still there either way in the
     source; the question is whether the shrink keeps them, and only one of
     the two does. The bound sits between the two measurements.

     A live pac-man.rom frame shows the same split at 106x80 -- 26% against
     12% -- lower on both sides because a game screen is mostly background,
     and the same factor of two apart. *)
  check bool
    (Printf.sprintf "strokes survive (%.0f%% of cells lit)" (ratio *. 100.))
    true
    (ratio > 0.60)
;;

(* Filling the terminal squashed a 256x192 frame to 0.6 of its height at wide
   sizes. The mosaic pixel is roughly square -- a cell is about twice as tall
   as it is wide and the half-block halves it -- so the drawn grid carries the
   frame's own ratio, and a row count that ignores it is the squash. *)
let test_the_frame_keeps_its_shape () =
  let out = drawn (stroked_frame ()) in
  let lines = String.split_on_char '\n' out in
  let body =
    List.filter (fun l -> String.length l > 0 && String.contains l '\027'
                          && Str.string_match (Str.regexp ".*38;2;") l 0)
      lines
  in
  check bool "there is a picture" true (List.length body > 2);
  (* Width in cells: count the foreground escapes on one body row. *)
  let row = List.nth body (List.length body / 2) in
  let cells = List.length (foreground_colours row) in
  let drawn_rows = List.length body in
  let ratio = float_of_int cells /. float_of_int (drawn_rows * 2) in
  let native = 256. /. 192. in
  check bool
    (Printf.sprintf "aspect %.2f is near the machine's %.2f" ratio native)
    true
    (Float.abs (ratio -. native) < 0.25)
;;

let () =
  run "masc_tui_msx render"
    [ ( "picture"
      , [ test_case "thin strokes survive the shrink" `Quick
            test_thin_strokes_survive_the_shrink
        ; test_case "the frame keeps its shape" `Quick
            test_the_frame_keeps_its_shape
        ] )
    ]
;;
