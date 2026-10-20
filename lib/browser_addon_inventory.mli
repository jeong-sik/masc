(** Typed worker inventory shared by owner publication and host selection. *)
val owned_to_json : Browser_selection.snapshot -> Yojson.Safe.t
val owned_of_json : Yojson.Safe.t ->
  (Browser_selection.work_browser * Browser_selection.work_browser, string) result
