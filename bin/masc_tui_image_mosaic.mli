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

    [(0, 0)] when either bound leaves no room or fitting the source width
    leaves fewer than two pixel rows. The caller draws an empty body rather
    than stretching a source too wide for an even-row grid. *)

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

val render :
  project:
    (Masc_tui_terminal_palette.rgb ->
    Masc_tui_terminal_palette.projected_color option) ->
  cols:int ->
  rows:int ->
  string ->
  string list
(** [render ~project ~cols ~rows rgb] renders row-major RGB bytes
    ([cols*rows*3] long) as [rows/2] mosaic lines of [cols] cells each: each
    cell's upper half is the top pixel (foreground) and its lower half the
    bottom pixel (background). [project] is the sole colour-capability decision
    (-- {!project_for_terminal} outside tests); when [project] returns [None]
    for a pixel, [render] returns [[]] so no colourless block stripes are
    drawn. Also returns [] when [cols]/[rows] are non-positive, [rows] is odd,
    or [rgb] is shorter than [cols*rows*3], so a malformed decode never draws
    garbage or raises. *)

val project_for_terminal :
  Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option
(** Terminal colour projector for mosaics: [None] when colour is disabled
    ({!Masc_tui_theme.colors_enabled} is false), otherwise
    {!Masc_tui_terminal_palette.best_color}. *)

val render_for_terminal : cols:int -> rows:int -> string -> string list
(** {!render} using {!project_for_terminal}. Exposed so callers such as
    {!Masc_tui_msx} need not depend on [masc_tui_terminal_palette] directly. *)

module For_testing : sig
  type color_capability =
    | Terminal
    | True_color
    | Ansi256
    | Disabled

  val render_with_capability :
    capability:color_capability -> cols:int -> rows:int -> string -> string list
end

val render_rgba :
  project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  cols:int ->
  rows:int ->
  string ->
  string list
(** [render_rgba ~project ~cols ~rows rgba]: row-major straight-alpha RGBA
    bytes ([cols*rows*4] long) as [rows/2] lines of [cols] cells, for a
    picture with a transparent surround. A pixel under half opacity is not
    drawn and the page shows there: a cell with one such half draws the other
    as a half block on the page colour (SGR 39/49), one with both is a space.
    Colours go through [project] -- {!project_for_terminal} outside tests --
    as the sole colour-capability decision; if [project] returns [None] for any
    opaque pixel, [render_rgba] returns [[]] rather than drawing colourless
    block stripes. Every line ends with the terminal's own colours (SGR 39 and
    49), never a full reset, so a row that styles itself keeps its style. [] on
    the same malformed input as {!render}. *)
