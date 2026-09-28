(** Pixels for a keeper portrait.

    A 2D renderer: every sample of a supersampled grid evaluates the candle's
    signed distance fields and asks which part of the candle it is on (wax,
    flame, horn, eye, an item, ...). Parts are cel-shaded with a light from
    the upper left using a bevel normal taken from the distance field near the
    silhouette; the flame and the sparkles in the eyes give light instead of
    taking it. Ink lines run round the silhouette and between parts. The
    candle stands on a round backdrop in the body's colour; outside the
    backdrop the image is transparent. *)

type rgb = { red : int; green : int; blue : int }

type size
(** A portrait's edge length in pixels. *)

val min_size : int
(** Smaller than this and the eyes are less than a pixel. *)

val max_size : int
(** The supersampled grid is held whole in memory; this bounds it. *)

val size_of_int : int -> size option
(** [None] outside [min_size, max_size]. *)

val int_of_size : size -> int

type image = private {
  edge : int;  (** width and height in pixels *)
  rgba : string;  (** [edge * edge * 4] bytes, rows top to bottom, straight alpha *)
}

val render : Keeper_portrait_look.body -> Keeper_portrait_look.equipment -> size -> image
(** The portrait: {!render_posed} with {!still}. Deterministic: the same
    arguments always give the same bytes. *)

(** {2 Motion}

    For animated uses such as the TUI splash. There is no clock in here: the
    caller says where in time it is, and the same pose always gives the same
    bytes. *)

type pose = {
  flicker : float;  (** in [-1, 1]: the flame grows and its tip sways *)
  blink : bool;  (** every eye closes *)
  bob : float;  (** in [-1, 1]: the candle rises or settles a pixel or two; the backdrop stays *)
}

val still : pose
(** No flicker, eyes as the body has them, no bob. *)

val pose_at : seconds:float -> pose
(** The pose at a moment of a loop that never visibly repeats: two flame
    waves, a short blink every few seconds, a slow bob. Pure. *)

val render_posed :
  Keeper_portrait_look.body -> Keeper_portrait_look.equipment -> pose -> size -> image

val pixel : image -> x:int -> y:int -> rgb * int
(** Colour and alpha of one pixel. [x] and [y] are clamped to the image. *)

(** Geometry and colours the tests check the pixels against. *)
module For_testing : sig
  val pixel_of_point : size -> float * float -> int * int
  (** The pixel a point in shape units (y grows downward) lands on. *)

  val wax_bounds : Keeper_portrait_look.body -> float * float * float * float
  (** Left, top, right and bottom edges of the wax block, shape units. *)

  val eye_centres : Keeper_portrait_look.body -> (float * float) list

  val flame_box : Keeper_portrait_look.body -> float * float * float * float
  (** Left, top, right, bottom of everything a flicker can change, shape units. *)

  val eye_boxes : Keeper_portrait_look.body -> (float * float * float * float) list
  (** Around each eye: everything a blink can change, shape units. *)

  val flame_probe : Keeper_portrait_look.body -> float * float
  (** A point inside the (first) flame, on its lower right where a lit solid
      would fall into the shade band. *)

  val ink : Keeper_portrait_look.body -> rgb
  val wax_rgb : Keeper_portrait_look.body -> rgb
  val flame_rgb : Keeper_portrait_look.body -> rgb
  val eye_rgb : Keeper_portrait_look.body -> rgb
  val backdrop_rgb : Keeper_portrait_look.body -> rgb
end
