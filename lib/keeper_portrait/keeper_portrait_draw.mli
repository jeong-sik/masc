(** Pixels for a keeper portrait.

    A 2D renderer: every sample of a supersampled grid evaluates the candle's
    signed distance fields and asks which part of the candle it is on (wax,
    flame, horn, eye, an item, ...). Parts are cel-shaded with a light from
    the upper left using a bevel normal taken from the distance field near the
    silhouette; the flame and the sparkles in the eyes give light instead of
    taking it. Ink lines run round the silhouette and between parts. The
    candle stands on a round backdrop in the body's colour and is not clipped
    to it: the tallest flame's tip, the dish's rim and a scarf's tail on a
    short candle can reach past the backdrop's edge. Nothing reaches the
    image border, at any pose. The square frame fits the backdrop and the
    whole outfit with a pixel of clearance. Full flicker and bob swings are
    included so the frame stays fixed during motion. Everything else outside
    the backdrop is transparent. *)

type rgb = { red : int; green : int; blue : int }

type size
(** A portrait's edge length in pixels. *)

val min_size : int
(** Smaller than this and the eyes are less than a pixel. *)

val max_size : int
(** The supersampled grid is held whole in memory, a distance and a part per
    sample (about 16 MB at this size); this bounds it. *)

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

val render_icon : Keeper_portrait_look.body -> Keeper_portrait_look.equipment -> size -> image
(** Face-centred identity thumbnail. Full outfit inspection uses [render]. *)

(** {2 Motion}

    For animated uses such as the /about candle. There is no clock in here: the
    caller says where in time it is, and the same pose always gives the same
    bytes. *)

type pose = private {
  flicker : float;  (** in [-1, 1]: the flame grows and its tip sways *)
  blink : bool;  (** every eye closes *)
  bob : float;  (** in [-1, 1]: the candle rises or settles; the backdrop stays *)
}

val pose : flicker:float -> blink:bool -> bob:float -> pose option
(** [None] when [flicker] or [bob] is outside [-1, 1] (NaN included). *)

val still : pose
(** No flicker, eyes as the body has them, no bob. *)

val pose_at : milliseconds:int -> pose
(** The pose at a moment of a loop that never visibly repeats: two flame
    waves, a short blink every few seconds, a slow bob. Pure; any integer is
    a moment, negative ones included. *)

val render_posed :
  Keeper_portrait_look.body -> Keeper_portrait_look.equipment -> pose -> size -> image

val render_compact_posed :
  Keeper_portrait_look.body -> Keeper_portrait_look.equipment -> pose -> size -> image
(** A simpler candle silhouette for terminal mosaics at 24–40 pixels. It
    keeps the face and flame large enough to read and leaves the backdrop
    transparent. Placed pixel portraits continue to use [render_posed]. *)

val pixel : image -> x:int -> y:int -> rgb * int
(** Colour and alpha of one pixel. [x] and [y] are clamped to the image. *)

(** The colours a body's parts are painted in: the table this renderer paints
    with, for one that draws the same candle another way
    ({!Keeper_portrait_solid}). *)
type palette = {
  wax_rgb : rgb;
  drip_rgb : rgb;
  flame_rgb : rgb;  (** the flame's body *)
  flame_core_rgb : rgb;  (** its hot centre *)
  horn_rgb : rgb;
  eye_rgb : rgb;
  glint_rgb : rgb;  (** the sparkle in an eye *)
  blush_rgb : rgb;
  mouth_rgb : rgb;
  ink_rgb : rgb;  (** outlines *)
  backdrop_rgb : rgb;
}

val palette : Keeper_portrait_look.body -> palette

val image_init : size -> (x:int -> y:int -> rgb * int) -> image
(** An {!image} another renderer draws: the colour and alpha at each pixel,
    [x] and [y] from 0 to the edge less one, channels clamped to 0-255. *)

(** Geometry and colours the tests check the pixels against. *)
module For_testing : sig
  val render_unculled :
    Keeper_portrait_look.body -> Keeper_portrait_look.equipment -> pose -> size -> image
  (** {!render_posed} evaluating every part at every sample, with no region
      skipped. It must give the same bytes. *)

  val render_in_frame_of :
    Keeper_portrait_look.body -> Keeper_portrait_look.equipment ->
    frame_of:Keeper_portrait_look.equipment -> pose -> size -> image
  (** Draw one outfit through another outfit's frame. Comparing their pixels
      then measures occlusion without mixing in a change of projection. *)

  val pixel_of_point : size -> float * float -> int * int
  (** The pixel a point in shape units (y grows downward) lands on in the
      default frame. *)

  val wax_bounds : Keeper_portrait_look.body -> float * float * float * float
  (** Left, top, right and bottom edges of the wax block, shape units. *)

  val eye_centres : Keeper_portrait_look.body -> (float * float) list
  val freckle_centres : Keeper_portrait_look.body -> (float * float) list

  val mouth_centre : Keeper_portrait_look.body -> float * float
  (** The middle of the mouth's centre line, shape units. *)

  val flame_box : Keeper_portrait_look.body -> float * float * float * float
  (** Left, top, right, bottom of everything a flicker can change, shape units. *)

  val eye_boxes : Keeper_portrait_look.body -> (float * float * float * float) list
  (** Around each eye: everything a blink can change, shape units. *)

  val flame_probe : Keeper_portrait_look.body -> float * float
  (** A point inside the (first) flame, on its lower right where a lit solid
      would fall into the shade band. *)

  val line_reach_pixels : size -> float
  (** How far past a boundary between two parts the ink line reaches, in
      output pixels. *)

  val ink : Keeper_portrait_look.body -> rgb
  val wax_rgb : Keeper_portrait_look.body -> rgb
  val flame_rgb : Keeper_portrait_look.body -> rgb
  val eye_rgb : Keeper_portrait_look.body -> rgb
  val mouth_rgb : Keeper_portrait_look.body -> rgb
  val tooth_rgb : Keeper_portrait_look.body -> rgb
  val beard_rgb : Keeper_portrait_look.body -> rgb
  val backdrop_rgb : Keeper_portrait_look.body -> rgb
end
