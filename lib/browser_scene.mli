(** A semantic viewport observation, not a browser paint/display list. *)
type rect = { x : float; y : float; width : float; height : float }
type kind = Text | Raster | Region of string | Control of { clickable : bool; editable : bool; disabled : bool }
type node = { node_id : string; kind : kind; tag : string; text : string;
  rects : rect list; color : string; font_size : float; font_weight : string; white_space : string; source_context : Browser_source_context.t }
type t = { document_id : string; url : string; title : string; width : float; height : float;
  scroll_x : float; scroll_y : float; nodes : node list; truncated : bool;
  view : Browser_lane.scene_view; scope : Browser_lane.node_ref option }
val of_json : Yojson.Safe.t -> (t, string) result
val read : ?expected_url:string -> ?view:Browser_lane.scene_view -> ?scope:Browser_lane.node_ref -> Browser_surface.request -> max_chars:int -> (Yojson.Safe.t, string) result

val scope_of_json : Yojson.Safe.t -> (Browser_lane.node_ref, string) result

val read_request : Yojson.Safe.t -> (Yojson.Safe.t, string) result
