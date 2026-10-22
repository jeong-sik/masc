(** The same browser observation on MCP and the concurrent private channel.
    Reading it never waits for a browser command's result. *)
val of_snapshot : observed_at:float -> Yojson.Safe.t ->
  (Lane_addon_types.output, string) result

(** What a serving browser worker published: its connected clients and
    whether its automation and Stagehand backends are registered. *)
type published = {
  clients : Browser_lane.client_info list;
  client_rows : Yojson.Safe.t list;
  (** The client rows as the worker sent them, for a caller that passes them on. *)
  automation : Browser_selection.work_browser;
  stagehand : Browser_selection.work_browser;
}

val decode_snapshot : Yojson.Safe.t -> (published, string) result
(** Read a browser worker snapshot. Only a serving worker's snapshot reads;
    a retired worker and any other shape are errors. *)

val read : Lane_addon_types.output -> (published, string) result
(** Read back the observation {!of_snapshot} published, from the cached
    output of the browser installation, whose row the runtime has renamed
    under its instance and sequence. *)
