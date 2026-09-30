(** The page [GET /api/v1/board] answers on HTTP/1 and HTTP/2. *)

val payload :
  ?config:Workspace.config ->
  reaction_actor:string option ->
  Httpun.Request.t ->
  Dashboard_cache.cached_payload
(** The page for the request's query ([hearth], [sort_by], [exclude_system],
    [exclude_automation], [author], [limit], [offset], [voter]) and the
    authenticated [reaction_actor]; a blank [hearth] or [author] is no filter.
    It is kept with its serialized body and entity tag for the realtime TTL,
    after which the dashboard cache serves it stale while it recomputes. A board
    write that raises a board event drops every [board:list:] entry sooner.
    [origin] is [Timeout] when the page could not be computed in time; the body
    is then the cache's timeout envelope. *)
