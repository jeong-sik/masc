(** Keeper trace reads for the dashboard: the raw trace files of a keeper's
    turns, and the trajectory of its tool calls. *)

val handle_raw_traces_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/raw-traces] with one summary per turn
    file ([limit] defaults to 25, from 1 to 200). A read error answers 400. *)

val handle_raw_trace_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/raw-trace?file=...] with the records of
    the one turn file the listing named ([offset] defaults to 0, [limit] to
    200, from 1 to 2000). A missing [file] answers 400, a turn that does not
    exist 404, and any other read error 400. *)

val handle_trajectory_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/trajectory] with the last [limit]
    entries of the keeper's trace ([limit] defaults to 50, from 1 to 500).
    [result_max_len] caps the result text of each entry (default 2000, from 0
    to 10000) and [include_thinking=true] also lists the entries that record
    withheld reasoning. An empty or invalid keeper name answers 400, a keeper
    without metadata 404 and an unreadable metadata store 500. The answer is
    cached for the shared hot-path interval. *)
