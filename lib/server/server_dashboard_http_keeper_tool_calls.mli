(** Keeper tool calls for the dashboard: the recent-call list, the exact execution
    lookup, the per-tool statistics and one stored result. *)

val tool_call_entries :
  keeper_name:string ->
  limit:int ->
  (Yojson.Safe.t list, Keeper_tool_call_log.index_error) result
(** Exact per-Keeper indexed tail, in chronological order, with the same tool
    definition annotations emitted by [/tool-calls]. An index that cannot be
    read is the [Error], which [/tool-calls] answers as 503
    [tool_call_store_unavailable]; it is never an empty list. *)

val keeper_tool_call_lookup_response :
  config:Workspace.config ->
  keeper_name:string ->
  Httpun.Request.t ->
  ([ `OK | `Bad_request | `Not_found | `Conflict | `Service_unavailable ]
   * Yojson.Safe.t) option
(** Exact execution lookup for the existing [GET /tool-calls] surface.
    [None] means the execution query is absent and the recent-list route must
    handle the request. Blank or repeated parameters return 400. A unique
    authoritative row returns 200, absence 404, multiple canonical rows 409,
    and unavailable storage 503. The request workspace and keeper scope every
    lookup; the recent-row window is never used. *)

val handle_stats_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/tool-stats] with the per-tool statistics of
    the last [window_hours] (default 24, from 1 to 168) and the freshness of their
    source, through the dashboard cache. A missing or invalid keeper name answers
    400. *)

val handle_result_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<keeper>/tool-result] with the status and body of
    [Server_keeper_tool_result.response]. *)

val handle_calls_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/tool-calls]: the exact lookup of
    [keeper_tool_call_lookup_response] when the query names an [execution_id],
    otherwise the most recent calls ([limit], default 50, from 1 to 200) with the
    freshness of their source. A missing or invalid keeper name answers 400 and an
    unreadable index 503. *)
