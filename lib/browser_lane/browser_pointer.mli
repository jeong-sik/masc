(** Pointer coordinates are fractions of an observed browser viewport, not terminal cells. *)
type point = { x : float; y : float }
type viewport = { document_id : string; width : float; height : float;
  scroll_x : float; scroll_y : float }
val point_of_json : Yojson.Safe.t -> (point, string) result
val viewport_of_json : Yojson.Safe.t -> (viewport, string) result
val point_to_json : point -> Yojson.Safe.t
val viewport_to_json : viewport -> Yojson.Safe.t
