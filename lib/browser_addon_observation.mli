(** The same browser observation on MCP and the concurrent private channel.
    Reading it never waits for a browser command's result. *)
val of_snapshot : observed_at:float -> Yojson.Safe.t ->
  (Lane_addon_types.output, string) result

(** A backend that does not serve while the rest of the worker does: a name
    refused at startup, whose ids are the user-owned Spaces that matched it,
    or a connection that ended because ego no longer lists the Space it was
    bound to, named by that Space's number and name. *)
type unavailable =
  | Ego_user_owned_name of { space : string; ids : int list; observed_at : float }
  | Ego_space_missing of { space : string; space_id : int; observed_at : float }
val unavailable_to_json : unavailable -> Yojson.Safe.t
val unavailable_of_json : Yojson.Safe.t -> (unavailable, string) result

val publish_client : Browser_lane.client_info ->
  space_observation:Browser_ego_space_observation.t option ->
  space_presence:Browser_ego_space_observation.presence option -> Yojson.Safe.t
(** Add the cached SDK observation to the ordinary connection/activity row.
    No SDK calls. Foreign Space IDs and non-Ego connections publish [null]. *)

(** What a serving browser worker published: its connected clients. *)
type published = {
  clients : Browser_lane.client_info list;
  space_presence : (Browser_lane.client_id * Browser_ego_space_observation.presence) list;
  client_rows : Yojson.Safe.t list;
  (** The client rows as the worker sent them, for a caller that passes them on. *)
  unavailable : unavailable list;
}

val decode_snapshot : Yojson.Safe.t -> (published, string) result
(** Read a browser worker snapshot. Only a serving worker's snapshot reads;
    a retired worker and any other shape are errors. *)

val read : Lane_addon_types.output -> (published, string) result
(** Read back the observation {!of_snapshot} published, from the cached
    output of the browser installation, whose row the runtime has renamed
    under its instance and sequence. *)

(** A worker of this source serves a live connection. *)
val serves_live : Browser_lane.Backend.t -> bool

type live_conflict = Duplicate_client of Browser_lane.client_id | Duplicate_ego_space of int
val live_conflicts : Browser_lane.client_info list -> live_conflict list
(** Conflicting client IDs or multiple controllers of one native Ego Space.
    Space IDs are scoped to the single Ego native runtime served by this MASC
    workspace; they are not globally unique across independent Ego runtimes. *)
val conflicts_with : Browser_lane.client_info -> live_conflict -> bool
val conflict_message : live_conflict -> string

type client_observation = Observed_clients of Browser_lane.client_info list | Unobserved_clients
type ego_identity_knowledge = Known_ego_identities | Unknown_ego_identities
val ego_identity_knowledge :
  (Browser_lane.Backend.t * client_observation) list -> ego_identity_knowledge
(** Every live-source publisher can report an Ego controller under the current
    snapshot contract. An unreadable or unready live publisher can therefore
    hide a conflicting controller. *)
val check_ego_identity : ego_identity_knowledge -> Browser_lane.client_info -> (unit, string) result
(** An Ego route requires all possible controllers' identities. Explicit
    non-Ego clients remain usable when another publisher is unreadable. *)

(** What several browser workers published, read as one, with each worker's
    source: unique live clients and unavailable backends of live workers. A
    worker that published nothing is [None]. The host chooses from this, and
    the lane rows read it. Live workers coexist; only actual client/Space
    conflicts are excluded, with metadata and presence filtered to the same
    client set. *)
val merge : (Browser_lane.Backend.t * published option) list -> published
