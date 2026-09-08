(** A semantic viewport observation, not a browser paint/display list. *)
type rect = { x : float; y : float; width : float; height : float }
type kind = Text | Raster | Control of { clickable : bool; editable : bool; disabled : bool }
type node = { node_id : string; kind : kind; tag : string; text : string;
  rects : rect list; color : string; font_size : float; font_weight : string; white_space : string }
type t = { document_id : string; url : string; title : string; width : float; height : float;
  scroll_x : float; scroll_y : float; nodes : node list; truncated : bool }
val of_json : Yojson.Safe.t -> (t, string) result
val read : Browser_surface.request -> max_chars:int -> (Yojson.Safe.t, string) result
