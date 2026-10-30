(** Server_activity_http — HTTP entry points for the activity
    graph (events / graph / swimlane).

    Three JSON-bodied dispatchers (events / graph / swimlane) +
    one helper ({!parse_since_ms}) for [since=...] query params. *)

(** {1 Capability injection} *)

type deps = {
  query_param : Httpun.Request.t -> string -> string option;
  int_query_param :
    Httpun.Request.t -> string -> default:int -> int;
}
(** The query-parameter readers the activity handlers use, passed in by
    {!Server_routes_http_routes_activity}. *)

(** {1 Helpers} *)

val parse_since_ms : string -> int option
(** [parse_since_ms raw] parses a relative timespec into
    milliseconds.  Recognised suffixes: [m] (minutes), [h]
    (hours), [d] (days).  Returns [None] for unrecognised
    formats.  Pure — exposed for unit testing
    ({!Test_activity_graph}).

    Examples:
    - [["5m"]] -> [Some 300_000]
    - [["1h"]] -> [Some 3_600_000]
    - [["7d"]] -> [Some 604_800_000]
    - [["5"]] / [["m"]] / [["bad"]] -> [None] *)

val slice_default_events_to_limit :
  Yojson.Safe.t -> limit:int -> Yojson.Safe.t
(** [slice_default_events_to_limit json ~limit] trims the
    ["events"] list inside a default-shaped activity response down
    to [limit] entries, dropping the oldest.  Updates ["count"],
    ["limit"], and ["next_after_seq"] accordingly.  Pure —
    exposed for unit testing ({!Test_server_activity_http}). *)

(** {1 JSON dispatchers}

    All three take [~deps ~state request] and return a
    {!Yojson.Safe.t} body.  Query-param contracts:

    - [kinds] / [kind]: comma-separated event-kind filter (both
      accepted; results unioned + deduped).
    - [after_seq] (events only): integer floor, defaults to [0].
    - [limit]: per-handler clamp (see each function's contract).
    - [since=Xm|Xh|Xd] (graph / swimlane only): relative window
      in minutes / hours / days; missing or unparseable -> no
      since filter. *)

val events_http_json :
  deps:deps ->
  state:Mcp_server.server_state ->
  Httpun.Request.t ->
  Yojson.Safe.t
(** [events_http_json] returns
    {!Activity_graph.json_response} for the requested
    [(kinds, after_seq, limit)].  Limit clamp:
    [\[1, 1000\]] (default 200). *)

val graph_http_json :
  deps:deps ->
  state:Mcp_server.server_state ->
  Httpun.Request.t ->
  Yojson.Safe.t
(** [graph_http_json] returns {!Activity_graph.graph_json} for
    the requested [(kinds, limit, timeline_limit, since_ms)].
    Limit clamps: main [\[50, 2000\]] (default 500), timeline
    [\[10, 200\]] (default 80). *)

val swimlane_http_json :
  deps:deps ->
  state:Mcp_server.server_state ->
  Httpun.Request.t ->
  Yojson.Safe.t
(** [swimlane_http_json] returns
    {!Activity_graph.agent_spans_json} for the requested
    [(limit, since_ms)].  Limit clamp: [\[1, 2000\]] (default
    500). *)
