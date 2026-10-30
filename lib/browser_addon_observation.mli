(** The same browser observation on MCP and the concurrent private channel.
    Reading it never waits for a browser command's result. *)
val of_snapshot : observed_at:float -> Yojson.Safe.t ->
  (Lane_addon_types.output, string) result

(** A backend that could not start while the rest of the worker serves. *)
type unavailable = Ego_user_owned_name of { space : string; observed_at : float }
val unavailable_to_json : unavailable -> Yojson.Safe.t
val unavailable_of_json : Yojson.Safe.t -> (unavailable, string) result

val publish_client : Browser_lane.client_info ->
  space_observation:Browser_ego_space_observation.t option -> Yojson.Safe.t
(** Add the cached SDK observation to the ordinary connection/activity row.
    No SDK calls. Foreign Space IDs and non-Ego connections publish [null]. *)

(** What a serving browser worker published: its connected clients and
    whether its automation and Stagehand backends are registered. *)
type published = {
  clients : Browser_lane.client_info list;
  client_rows : Yojson.Safe.t list;
  (** The client rows as the worker sent them, for a caller that passes them on. *)
  automation : Browser_selection.work_browser;
  stagehand : Browser_selection.work_browser;
  unavailable : unavailable list;
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

(** A worker of this source serves a live connection. *)
val serves_live : Browser_lane.Backend.t -> bool

(** Whether a worker of [backend] answers for [lane], among the sources of
    every serving worker [among] (itself included): its source is of that
    lane and no other worker serves it. What a worker publishes does not say
    which worker of its source it came from, so a doubled source leaves every
    worker serving it out of that lane. *)
val answers_for : among:Browser_lane.Backend.t list -> Browser_lane.Lane_name.t ->
  Browser_lane.Backend.t -> bool

(** Whether a worker of [backend] lists clients the host may use: whether
    it {!answers_for} the live lane. *)
val lists_usable_clients : among:Browser_lane.Backend.t list -> Browser_lane.Backend.t -> bool

(** What several browser workers published, read as one, with each worker's
    source: the clients and unavailable backends of every worker that
    {!lists_usable_clients}, and the
    automation and Stagehand reports of the one worker that serves each, when
    exactly one does and it published; otherwise {!unobserved}. A worker that
    published nothing is [None] and still counts as serving its source. The
    host chooses from this, and the lane rows read it. *)
val merge : among:Browser_lane.Backend.t list ->
  (Browser_lane.Backend.t * published option) list -> published
(** [among] lists the source of every worker the caller counts as serving,
    which may be more than the workers read here; a live source is doubled
    when two of them serve it. The host counts its ready services; presence
    counts one entry per source it reads. *)
