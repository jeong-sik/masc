(** Closed browser actions; selectors and text remain data. *)
type request = { source : Browser_surface.source; tab_id : int;
  expected_url : string option; action : Browser_lane.interaction }
val parse : Yojson.Safe.t -> (request, string) result
val script : string
(** Fixed DOM implementation. WebDriver supplies the parsed action as argument
    zero; the live extension uses the same function with JSON-encoded data. *)
