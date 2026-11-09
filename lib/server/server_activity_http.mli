(** Server_activity_http — HTTP entry point for the activity event log.

    One JSON-bodied dispatcher ({!events_http_json}) and the helper that
    trims a default-shaped response to the requested limit. *)

(** {1 Capability injection} *)

type deps = {
  query_param : Httpun.Request.t -> string -> string option;
  int_query_param :
    Httpun.Request.t -> string -> default:int -> int;
}
(** The query-parameter readers the activity handlers use, passed in by
    {!Server_routes_http_routes_activity}. *)

(** {1 Helpers} *)

val slice_default_events_to_limit :
  Yojson.Safe.t -> limit:int -> Yojson.Safe.t
(** [slice_default_events_to_limit json ~limit] trims the
    ["events"] list inside a default-shaped activity response down
    to [limit] entries, dropping the oldest.  Updates ["count"],
    ["limit"], and ["next_after_seq"] accordingly.  Pure —
    exposed for unit testing ({!Test_server_activity_http}). *)

(** {1 JSON dispatcher}

    Takes [~deps ~state request] and returns a
    {!Yojson.Safe.t} body.  Query-param contracts:

    - [kinds] / [kind]: comma-separated event-kind filter (both
      accepted; results unioned + deduped).
    - [after_seq]: integer floor, defaults to [0].
    - [limit]: clamp described on {!events_http_json}. *)

val events_http_json :
  deps:deps ->
  state:Mcp_server.server_state ->
  Httpun.Request.t ->
  Yojson.Safe.t
(** [events_http_json] returns
    {!Activity_graph.json_response} for the requested
    [(kinds, after_seq, limit)].  Limit clamp:
    [\[1, 1000\]] (default 200). *)
