(** Pointer coordinates are fractions of an observed browser viewport, not terminal cells. *)
type point = { x : float; y : float }
type viewport = { document_id : string; width : float; height : float;
  scroll_x : float; scroll_y : float }
val point_of_json : Yojson.Safe.t -> (point, string) result
val viewport_of_json : Yojson.Safe.t -> (viewport, string) result
val point_to_json : point -> Yojson.Safe.t
val viewport_to_json : viewport -> Yojson.Safe.t

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

(** Native WebDriver/BiDi input sources. A click presses and releases the
    button's WebDriver pointer button: 0 for [Primary], 1 for [Middle], 2 for
    [Secondary]. Drag visits every supplied waypoint
    and moves over the destination twice before releasing. An empty path
    visits the midpoint first, so activation and destination movement occur
    at distinct positions when their CSS-pixel coordinates differ. This lets dragover
    handlers observe the destination where the browser supports native HTML
    drag-and-drop; it does not prove that the application accepted a drop. [duration_ms] applies to each drag move;
    the initial positioning and the final repeated move have zero duration.
    Callers retain ownership of release/cancellation and input validation. *)
val input_sources :
  pointer_id:string -> wheel_id:string -> viewport:viewport -> start:point ->
  gesture -> Yojson.Safe.t
