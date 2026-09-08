(** Closed browser actions; selectors and text remain data. *)
type request = { source : Browser_surface.source; tab_id : int; client_id : Browser_lane.client_id option;
  expected_url : string option; action : Browser_lane.interaction }
val parse : Yojson.Safe.t -> (request, string) result
val perform : request -> (Yojson.Safe.t, string) result
(** Dispatch once to the explicitly selected lane/client/tab. No automatic retry. *)
val script : string
(** Fixed DOM implementation. WebDriver supplies the parsed action as argument
    zero; the live extension uses the same function with JSON-encoded data. *)
