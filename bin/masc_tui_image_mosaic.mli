(** Masc_tui_image_mosaic — render a small RGB pixel grid as a truecolor
    half-block ("▀") mosaic. Draws as ordinary coloured text, so it scrolls and
    redraws like any other card row on every truecolour terminal. *)

val fit_grid : src_w:int -> src_h:int -> max_cols:int -> max_rows:int -> int * int
(** The largest [(cols, rows)] pixel grid inside [max_cols x max_rows] that
    keeps [src_w : src_h]. A mosaic pixel is one cell wide and half a cell
    tall, and a terminal cell is about twice as tall as it is wide, so a grid
    with the source's ratio draws the source's shape. [rows] is even because
    each character cell stacks two of them; the rounding that makes it even
    can leave the ratio off by less than one pixel row.

    [(0, 0)] when either bound leaves no room, which the caller draws as an
    empty body rather than as a stretched picture. *)

val downscale :
  src_w:int -> src_h:int -> cols:int -> rows:int -> string -> string
(** Average the source pixels that fall inside each grid cell.

    Point-sampling a shrink keeps one source pixel per output pixel and drops
    the rest, so a feature thinner than the ratio survives only when the
    sample happens to land on it -- on pixel art that is a line that flickers
    between frames. Averaging gives every source pixel a share. The mosaic
    writes 24-bit colour, so the average is what reaches the terminal.

    [""] when [rgb] is shorter than [src_w * src_h * 3], so a short decode
    draws nothing rather than reading past its end. *)

val render : cols:int -> rows:int -> string -> string list
(** [render ~cols ~rows rgb] renders row-major RGB bytes ([cols*rows*3] long) as
    [rows/2] mosaic lines of [cols] cells each: each cell's upper half is the top
    pixel (foreground) and its lower half the bottom pixel (background). Returns
    [] when [cols]/[rows] are non-positive, [rows] is odd, or [rgb] is shorter
    than [cols*rows*3], so a malformed decode never draws garbage or raises. *)
