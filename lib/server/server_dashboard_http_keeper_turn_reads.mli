(** Keeper turn reads for the dashboard: the recent turn records with what
    each changed in the prompt, the exact lookup of one record, and the
    transcript of one turn. *)

val keeper_turn_record_lookup_response :
  config:Workspace.config ->
  keeper_name:string ->
  Httpun.Request.t ->
  ([ `OK | `Bad_request | `Not_found | `Service_unavailable ]
   * Yojson.Safe.t) option
(** Exact [GET /turn-records?turn_ref=...] lookup. [None] means no exact query
    was supplied, so the existing recent-page handler owns the request.
    Malformed/repeated queries return 400; a canonical match returns 200,
    readable absence 404, and unreadable or indeterminate history 503.
    The shared I/O pool owns the scan; failures never rerun it inline. *)

val keeper_turn_transcript_lookup_response :
  config:Workspace.config ->
  keeper_name:string ->
  Httpun.Request.t ->
  [ `OK | `Bad_request | `Service_unavailable ] * Yojson.Safe.t
(** Required, unique Turn_ref query. Strict retained-history read through the
    shared I/O pool: malformed query 400, unreadable/incomplete observation 503,
    and a readable transcript (including explicit absence) 200. The successful
    envelope includes the v2 schema identifying the retained-history contract. *)

val handle_records_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/turn-records]. With a [turn_ref] query
    the answer is [keeper_turn_record_lookup_response]. Without one it is the
    last [limit] turn records (default 50, from 1 to 500), each with the
    prompt-block changes against the record before it, and the health of the
    record store. An empty or invalid keeper name answers 400 and an unreadable
    record store 500. *)

val handle_transcript_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/turn-transcript?turn_ref=...] with
    [keeper_turn_transcript_lookup_response]. An empty or invalid keeper name
    answers 400 before the lookup runs. *)
