(** Pointer coordinates are fractions of an observed browser viewport, not terminal cells. *)
type point = { x : float; y : float }
type viewport = { document_id : string; width : float; height : float;
  scroll_x : float; scroll_y : float }
val point_of_json : Yojson.Safe.t -> (point, string) result
val viewport_of_json : Yojson.Safe.t -> (viewport, string) result
val point_to_json : point -> Yojson.Safe.t
val viewport_to_json : viewport -> Yojson.Safe.t

type gesture =
  | Hover
  | Click
  | Double_click
  | Drag of { via : point list; destination : point; duration_ms : int }
  | Wheel of { x : int; y : int }

(** Native WebDriver/BiDi input sources. Drag visits every supplied waypoint
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
