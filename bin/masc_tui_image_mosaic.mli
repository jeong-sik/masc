(** Masc_tui_image_mosaic — render a small RGB pixel grid as a truecolor
    half-block ("▀") mosaic. Draws as ordinary coloured text, so it scrolls and
    redraws like any other card row on every truecolour terminal. *)

val render : cols:int -> rows:int -> string -> string list
(** [render ~cols ~rows rgb] renders row-major RGB bytes ([cols*rows*3] long) as
    [rows/2] mosaic lines of [cols] cells each: each cell's upper half is the top
    pixel (foreground) and its lower half the bottom pixel (background). Returns
    [] when [cols]/[rows] are non-positive, [rows] is odd, or [rgb] is shorter
    than [cols*rows*3], so a malformed decode never draws garbage or raises. *)
