(** The imp emblem's two flat marks -- a horned imp's head and the lantern it
    keeps -- as signed distance fields.

    Coordinates are the emblem's own: [x] grows to the right and [y] grows
    downward, like the screen, and both marks sit inside the square
    [-extent .. extent]. A mark is flat here; {!Masc_tui_imp_emblem} gives it
    depth and turns it.

    Pure: no I/O, no global state. *)

type mark =
  | Imp
  | Lantern

val extent : float
(** Half the side of the square both marks fit in. *)

val grid : int
(** Samples per side of a {!field}. *)

val step : float
(** Distance between two neighbouring samples of a {!field}. *)

val depth_in : mark -> x:float -> y:float -> float
(** How far the point is inside the mark: positive inside, negative outside,
    zero on the outline. Holes the mark cuts (the imp's eyes and grin, the
    lantern's window) count as outside. *)

type field
(** {!depth_in} sampled on a [grid] x [grid] lattice over the square. *)

val field : mark -> field
(** Samples the mark. It costs [grid * grid] evaluations of {!depth_in}, so a
    caller builds each mark's field once and keeps it. *)

val sample : field -> col:int -> row:int -> float
(** The sample at lattice [col], [row], both in [0 .. grid - 1]; the point is
    [(-extent + col * step, -extent + row * step)]. Raises [Invalid_argument]
    outside the lattice. *)

type point =
  { x : float
  ; y : float
  }

(** Points the marks are built around. The shapes are defined from these, so a
    test can ask what is drawn at a feature without repeating its position. *)

val imp_left_eye : point
val imp_right_eye : point

val imp_grin_middle : point
(** The lowest point of the grin's arc. *)

val imp_brow : point
(** Solid head between and above the eyes. *)

val imp_left_horn : point
(** Inside the upper half of the left horn. *)

val lantern_handle_top : point
(** The top of the lantern's carrying ring. *)
