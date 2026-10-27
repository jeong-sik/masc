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

(** No serving worker published for this source. *)
val unobserved : Browser_selection.work_browser

(** A worker of these sources serves a live connection. *)
val serves_live : Lane_addon_types.browser_backends -> bool

(** Whether a worker of [backends] lists clients the host may use, among the
    sources of every serving worker [among] (itself included): it serves a
    live source and no live source it serves is served by another worker. A
    client does not say which source it came from, so a doubled live source
    leaves every client of the workers serving it unused. *)
val lists_usable_clients : among:Lane_addon_types.browser_backends list -> Lane_addon_types.browser_backends -> bool

(** What several browser workers published, read as one, with each worker's
    sources: the clients of every worker that {!lists_usable_clients}, and the
    automation and Stagehand reports of the one worker that serves each, when
    exactly one does and it published; otherwise {!unobserved}. A worker that
    published nothing is [None] and still counts as serving its sources. The
    host chooses from this, and the lane rows read it. *)
val merge : among:Lane_addon_types.browser_backends list ->
  (Lane_addon_types.browser_backends * published option) list -> published
(** [among] are the sources of every serving worker, which may be more than
    the workers read here; a live source is doubled when two of them serve it. *)
