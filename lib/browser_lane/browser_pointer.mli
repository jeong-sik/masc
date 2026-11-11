(** Pointer coordinates are fractions of an observed browser viewport, not terminal cells. *)
type point = { x : float; y : float }
type viewport = { document_id : string; width : float; height : float;
  scroll_x : float; scroll_y : float }
val point_of_json : Yojson.Safe.t -> (point, string) result
val viewport_of_json : Yojson.Safe.t -> (viewport, string) result
val point_to_json : point -> Yojson.Safe.t
val viewport_to_json : viewport -> Yojson.Safe.t

(** The CSS pixel, from the viewport's top left, that [point] names in
    [viewport]: each fraction times that side, truncated. *)
val viewport_pixels : viewport -> point -> int * int

(** The mouse button of a click. [Primary] is the one a plain click uses. *)
type button = Primary | Middle | Secondary

val button_of_string : string -> button option
val button_to_string : button -> string

type gesture =
  | Hover
  | Click of button
  | Double_click
  | Drag of { via : point list; destination : point; duration_ms : int }
  | Wheel of { x : int; y : int }
  | Tap  (** A touch pointer pressing and releasing at the start point. *)
  | Swipe of { via : point list; destination : point; duration_ms : int }
      (** A touch pointer held through the same path a drag takes. *)

val drag_waypoints : start:point -> destination:point -> point list -> point list
(** The supplied intermediate route, or its midpoint when empty. Does not
    include the destination or dispatch input; each adapter owns button release. *)
