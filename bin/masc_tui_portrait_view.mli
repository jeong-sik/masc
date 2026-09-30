(** A candle portrait ({!Keeper_portrait_draw}) on the terminal.

    Three ways, chosen once per process from what the terminal said about
    itself at start:

    - real pixels, where the terminal answered the Kitty graphics query and
      said what a cell measures: the frame leaves the picture's rows blank and the picture is placed over
      them after the frame is on screen, as straight-alpha RGBA so the
      terminal blends its transparent surround over the page;
    - a half-block mosaic of coloured text everywhere else -- a Kitty
      terminal that did not say what a cell measures included, because a
      placed picture's box is counted in cells from that size --, two pixels
      to a cell, with transparent pixels left to the page colour;
    - nothing under NO_COLOR, or on a stdout that projects no colour: a
      picture is exactly the colour NO_COLOR opts out of, and the candle's
      shape without colour reads as noise. *)

type display =
  | Pixels of { cell_width : int; cell_height : int }
      (** Kitty graphics. The cell size is what the terminal reported, in
          pixels. *)
  | Mosaic  (** Half blocks of coloured text. *)
  | No_picture  (** NO_COLOR, or no colour to project. *)

val display_of :
  kitty:bool ->
  cell_pixels:(int * int) option ->
  colors_enabled:bool ->
  projects_colour:bool ->
  display
(** [kitty]: the terminal answered the graphics query. [cell_pixels]: what it
    said a cell measures; without a size it can use, a Kitty terminal draws
    the mosaic. [projects_colour]: stdout draws at least 256 colours. Colour
    off wins over everything: no picture at all. *)

type box = private {
  cols : int;  (** cells across *)
  rows : int;  (** cells down *)
  size : Keeper_portrait_draw.size;  (** the square picture's edge to render at *)
}

val fit : display -> max_cols:int -> max_rows:int -> box option
(** The largest square picture the space holds. [None] when the display
    draws none, or when the space leaves less than a readable picture:
    fewer than {!min_pixel_rows} cell rows for real pixels, or a mosaic
    edge under the renderer's {!Keeper_portrait_draw.min_size}. The edge is
    capped so one frame renders in a small part of [/about]'s 150 ms step:
    pixels are placed and scaled by the terminal, so a larger edge costs
    render time and buys little. *)

val min_pixel_rows : int
val pixel_edge_cap : int
val mosaic_edge_cap : int

val lines :
  project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  display ->
  box ->
  Keeper_portrait_draw.image ->
  string list
(** The picture's rows: [box.rows] rows of [box.cols] cells. Blank for
    {!Pixels} -- the picture is placed over them --, half blocks for
    {!Mosaic} ({!Masc_tui_image_mosaic.render_rgba}, which says how the
    transparent surround and the colours are drawn), [[]] for
    {!No_picture}. [project] is {!Masc_tui_terminal_palette.best_color}
    outside tests. *)

(** {2 Pictures placed over a frame}

    A frame asks for its pictures while it is built ({!request}); once the
    frame is on the terminal the main loop calls {!flush}, which places what
    was asked for and deletes what no longer is. *)

type placement = {
  image_id : int;  (** the picture's {!Masc_tui_graphics.image_id} *)
  row : int;  (** 0-based frame line of the picture's top edge *)
  column : int;  (** 0-based cell of its left edge *)
  box : box;
  image : Keeper_portrait_draw.image;
}

val placement_bytes : placement -> string
(** Save the cursor, move to the corner, transfer the pixels under the
    placement's id, which also places them, restore the cursor. [""] when
    the encoder refuses the pixels. *)

val put_bytes : placement -> string
(** Save the cursor, move to the corner, place the pixels the terminal
    already holds under the placement's id ({!Masc_tui_graphics.put}),
    restore the cursor. No pixels travel. *)

val set_display : display -> unit
(** What this terminal draws. Set once, after the start-up probe. Until then
    {!No_picture}. *)

val current_display : unit -> display

val begin_frame : unit -> unit
(** Forget what the last frame asked for. Called once for every frame, drawn
    or skipped. *)

val request : placement -> unit
(** The frame being built wants this picture on screen. *)

(** What one presented frame sends for one picture it asked for. *)
type send =
  | Keep  (** the terminal still shows this picture where it was placed *)
  | Put
      (** the terminal still holds these pixels: place them again, a few
          dozen bytes. For a picture that moved, and for one a rewritten
          row crossed. *)
  | Transmit
      (** send the pixels, which places them. For a new or changed picture,
          and after a clear screen, which takes the pixels with the
          placements. *)

val send :
  Masc_tui_frame_presenter.present_result -> shown:placement option -> placement -> send
(** [shown]: what the terminal was last sent under the picture's id.
    [Presented Whole_screen] cleared the screen ([ESC [2J]); [Presented
    (Rows rows)] erased ([ESC [2K]) and wrote these 0-based rows again;
    [Unchanged] wrote nothing. *)

val flush : Masc_tui_frame_presenter.present_result -> write:(string -> unit) -> unit
(** After a frame reached the terminal, or after nothing did ([Unchanged]).
    Sends each requested picture what {!send} says, and deletes every
    picture the frame no longer asks for. A picture the protocol encoder
    refuses is not counted as on screen, so the next frame tries it again.
    [write] must carry the bytes to the terminal as they are (wrapped for
    tmux by the caller). A screen that takes the whole terminal -- a
    picture, the MSX screen -- retires ours with {!begin_frame} and a flush:
    deleting what someone else's delete-all already took is a no-op for the
    terminal. *)
