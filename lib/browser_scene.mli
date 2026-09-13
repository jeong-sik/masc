type navigation_source = { url : string; document_id : string }
val navigation_source_of_json : Yojson.Safe.t -> (navigation_source, string) result
(** A semantic viewport observation, not a browser paint/display list. *)
type rect = { x : float; y : float; width : float; height : float }
type region_role =
  | Main
  | Navigation
  | Complementary
  | Named_region
  | Section
  | Article
  | Header
  | Footer
  | Search
  | Form
  | Log
  | Banner
  | Content_info
  | Scroll_area
  | Unknown of string
val region_role_of_string : string -> region_role
val region_role_to_string : region_role -> string
type kind =
  | Text
  | Raster
  | Region of region_role
  | Control of {
      clickable : bool;
      editable : bool;
      disabled : bool;
      href : string option;
    }
type region_ref = { node_id : string; role : region_role; label : string }
type text_role = Plain_text | Heading of int
val text_role_of_tag : string -> text_role
type node = { node_id : string; kind : kind; tag : string; text : string;
  heading_level : int option;
  ancestor_region : region_ref option;
  rects : rect list; color : string; font_size : float; font_weight : string; white_space : string; source_context : Browser_source_context.t }
val text_role : node -> text_role
type t = { document_id : string; url : string; title : string; width : float; height : float;
  scroll_x : float; scroll_y : float; nodes : node list; truncated : bool;
  view : Browser_lane.scene_view; scope : Browser_lane.node_ref option }
val of_json : Yojson.Safe.t -> (t, string) result
val read : ?navigation_source:navigation_source -> ?expected_url:string -> ?view:Browser_lane.scene_view -> ?scope:Browser_lane.node_ref -> Browser_surface.request -> max_chars:int -> (Yojson.Safe.t, string) result

val scope_of_json : Yojson.Safe.t -> (Browser_lane.node_ref, string) result

val read_request : Yojson.Safe.t -> (Yojson.Safe.t, string) result
