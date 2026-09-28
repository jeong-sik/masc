(** A turning imp emblem, drawn in Braille for the terminal.

    The imp and its lantern ({!Masc_tui_imp_shape}) are flat marks. Each is
    stood up as a slab with bevelled edges, its surface points are projected
    through a depth buffer, every point is lit, and each character cell becomes
    one Braille glyph -- two dots across, four down -- coloured with the mean
    of the dots it lights. Over one loop the emblem turns twice and changes
    from the imp to the lantern and back.

    Technique after openai/codex [codex-rs/tui/src/empty_state_animation]
    (Apache-2.0); reimplemented here with this emblem's own shapes, lights and
    palette.

    Nothing here reads the terminal or the clock. A frame is a function of the
    size, the pose and the lighting, so the same three give the same frame. *)

(** {1 Size} *)

type size = private
  { cols : int
  ; rows : int
  }
(** A box the emblem can be drawn in. Only {!fit} makes one, so a size is
    always within {!max_cols} x {!max_rows} and at least {!min_rows} tall. *)

val max_rows : int
val max_cols : int

val min_rows : int
(** Below this the face no longer reads: the eyes and grin fall between
    dots. *)

val fit : cols:int -> rows:int -> size option
(** The largest emblem box inside [cols] x [rows]. A Braille dot is about as
    wide as it is tall, so the box is two columns per row. [None] when the
    space is shorter than {!min_rows} or narrower than twice that. *)

(** {1 Pose} *)

type pose = private
  | Turning of float
      (** Where in the loop, in [0.0, 1.0). One loop is two turns: the imp
          becomes the lantern as the first turn ends and the imp again as the
          second ends. *)
  | Settled
      (** The imp held still, turned a little so its bevel shows. For a
          screen that does not animate: NO_COLOR, reduced motion, a paused
          surface. *)

val turning : float -> pose option
(** The pose at [phase] loops; the whole part is dropped, so a caller can
    pass elapsed seconds divided by {!loop_seconds}. [None] for a phase that
    is not finite. *)

val settled : pose

val loop_seconds : float
(** How long one loop is meant to take on screen. *)

(** {1 Lighting} *)

type backdrop =
  | Known of Masc_tui_terminal_palette.t
      (** The terminal said its foreground and background. *)
  | Page of Masc_tui_terminal_palette.theme_mode
      (** The terminal said only whether its page is light or dark. *)
  | Unknown  (** The terminal said neither. *)

type lighting

val lighting : backdrop -> lighting
(** How the emblem is lit against the terminal's page.

    - A dark known page: warm ember tones, fading toward the page's own
      colour with depth.
    - A light known page: shading in the terminal's own text colour, like a
      pencil drawing, fading toward the page.
    - A page known only as dark or light: the matching tones, with no fade,
      since the page colour is not known.
    - Unknown: no colour at all -- the dots alone draw the shape in the
      terminal's own text colour, rather than guess at a page. *)

(** {1 Frames} *)

type cell =
  { dots : int
        (** Lit Braille dots, as the low eight bits of the Unicode offset
            from U+2800. Zero is an empty cell. *)
  ; ink : Masc_tui_terminal_palette.rgb option
        (** The mean colour of the lit dots. [None] in an empty cell and
            under {!Unknown} lighting. *)
  }

type frame = private
  { size : size
  ; cells : cell array  (** Row-major, [size.cols * size.rows] cells. *)
  }

type t
(** A renderer: both marks sampled once, and the buffers a frame is drawn
    into, kept between frames. Not safe to share between two fibers drawing at
    the same time. *)

val create : unit -> t
(** Samples both marks. Build one and keep it. *)

val frame : t -> size -> pose -> lighting -> frame
(** Draws one frame. The same size, pose and lighting give the same cells.
    Only cells inside [size] exist, and the frame shares no memory with [t],
    so the next call does not change it. *)

(** {1 Text} *)

val lines : ink:(Masc_tui_terminal_palette.rgb -> string) -> frame -> string list
(** One string per row, each exactly [size.cols] display cells: a Braille
    glyph per lit cell, a space per empty one. [ink] is the escape that sets
    a cell's colour; it is written only when the colour changes, and no row
    leaves a colour in effect after it ends. An [ink] that returns the empty
    string, or a frame with no ink, gives rows with no escapes at all. *)

val stdout_ink : Masc_tui_terminal_palette.rgb -> string
(** The [ink] for this process's stdout: the colour projected for what the
    terminal can draw ({!Masc_tui_terminal_palette.best_color}) and written by
    {!Masc_tui_theme.Sgr.foreground}, so NO_COLOR and a sixteen-colour
    terminal get no colour escapes, as everywhere else in the TUI. *)

(** Test-only access to the projection the renderer uses. *)
module For_testing : sig
  val dot_of_front_point :
    size -> pose -> Masc_tui_imp_shape.point -> (int * int * int) option
  (** Where a point on the mark's front face lands for [pose]: the cell as
      [col], [row], and the bit of its dot in that cell's [dots]. [None] when
      it lands outside [size]. *)
end
