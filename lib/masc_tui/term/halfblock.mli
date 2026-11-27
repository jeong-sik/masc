(** Pure-OCaml Unicode half-block (['▀'] U+2580) 24-bit truecolor image
    renderer for standard, tmux, and non-graphics terminals.

    Each terminal cell represents two vertically stacked pixels: the top pixel
    in foreground RGB and the bottom pixel in background RGB, alpha-composited
    over the target background color. *)

open Masc_tui_core

type viewport = {
  src_x : int;
  src_y : int;
  src_w : int;
  src_h : int;
}

val upper_half_block : string
(** UTF-8 encoding of U+2580 UPPER HALF BLOCK (["\xe2\x96\x80"]). *)

val fit_cells :
  image_pixels:int * int -> columns:int -> rows:int -> int * int
(** Compute aspect-preserving [(cols, rows)] inside [(columns, rows)] assuming
    1:2 monospace cells where each cell holds 1x2 half-block subpixels
    (effective 1:1 subpixel aspect). *)

val draw_rgba :
  ?viewport:viewport ->
  ?bg_rgb:int ->
  Cell_grid.t ->
  rect:Rect.t ->
  Png_decode.rgba_image ->
  unit
(** Render [image] (or its cropped [viewport] region) into [rect] on [grid]
    using 24-bit RGB foreground/background ['▀'] half-block cells. Uses box
    averaging when downsampling and nearest-neighbor when zooming in. *)
