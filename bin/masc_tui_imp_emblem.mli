(** A turning imp emblem, drawn in Braille for the terminal.

    The imp and its lantern ({!Masc_tui_imp_shape}) are flat marks. Each is
    stood up as a slab with bevelled edges, its surface points are projected
    through a depth buffer, every point is lit, and each character cell becomes
    one Braille glyph -- two dots across, four down -- coloured with the mean
    of the dots it lights. Over one loop the emblem turns twice and changes
    from the imp to the lantern and back.

    Adapted from openai/codex [codex-rs/tui/src/empty_state_animation]
    (Apache License 2.0, Copyright 2025 OpenAI): the frame, shading and loop
    follow Codex's; the marks, palettes, culling and constants were changed.
    The implementation says what came from where; the license and NOTICE are
    listed in THIRD-PARTY-LICENSES.md.

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

type cell = private
  { dots : int
        (** Lit Braille dots, as the low eight bits of the Unicode offset
            from U+2800. Zero is an empty cell. *)
  ; ink : Masc_tui_terminal_palette.rgb option
        (** The mean colour of the lit dots. [None] in an empty cell and
            under {!Unknown} lighting. *)
  }
(** Only {!frame} makes a cell, so [dots] is always one of the 256 Braille
    patterns and {!lines} always writes one display cell for it. *)

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

type ink
(** How a cell's colour is projected for the terminal. The escape bytes are
    always written by {!Masc_tui_theme.Sgr.foreground} from a
    {!Masc_tui_terminal_palette.projected_color}, which only the palette
    module makes, so no caller can put a colour on screen that the terminal
    was not projected for. *)

val stdout_ink : ink
(** This process's stdout: {!Masc_tui_terminal_palette.best_color}, so a
    sixteen-colour terminal gets no colour escapes, as everywhere else in the
    TUI. *)

val ink_projected_by :
  (Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) -> ink
(** An ink with another projection, such as a test fixing the colour level. *)

val lines : ink:ink -> frame -> string list
(** One string per row, each exactly [size.cols] display cells: a Braille
    glyph per lit cell, a space per empty one. A colour escape is written
    only when a cell's colour changes. A cell whose colour projects to
    nothing is drawn in the terminal's own text colour. Every row that set a
    colour ends with SGR 39 (default foreground) rather than a full reset,
    so a pane's own background and weight survive the emblem. With colours
    off (NO_COLOR), or a frame with no ink, rows have no escapes at all. *)

(** Test-only access to the projection the renderer uses. *)
module For_testing : sig
  val dot_of_front_point :
    size -> pose -> Masc_tui_imp_shape.point -> (int * int * int) option
  (** Where a point on the mark's front face lands for [pose]: the cell as
      [col], [row], and the bit of its dot in that cell's [dots]. [None] when
      it lands outside [size]. *)
end
