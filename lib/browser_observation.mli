(** Complete retained observations. These bytes describe a past read; they do
    not authorize interaction with the current browser. *)
type t = private {
  scene : Browser_scene.t;
  source : Browser_surface.source;
  client_id : Browser_lane.client_id option;
  tab_id : int;
}
val mime : string
val of_json : Yojson.Safe.t -> (t, string) result
(** Rejects duplicate object keys at every depth before interpreting identity
    or scene fields, so stored observations have one JSON meaning. *)
val retain : base_path:string -> view:Browser_lane.scene_view -> Tool_result.result -> (Tool_result.result, string) result
(** Validate and persist a completed scene before publishing its typed retained
    reference. Model data and its inline/composition projection are unchanged.
    Failed/deferred results pass through. Storage failures produce no reference. *)
