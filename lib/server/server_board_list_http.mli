(** The page [GET /api/v1/board] answers on HTTP/1 and HTTP/2. *)

val payload :
  ?config:Workspace.config ->
  reaction_actor:string option ->
  Httpun.Request.t ->
  Dashboard_cache.cached_payload
(** The page for the request's query ([hearth], [sort_by], [exclude_system],
    [exclude_automation], [author], [limit], [offset], [voter]) and the
    authenticated [reaction_actor]. It is kept with its serialized body and
    entity tag until the realtime TTL passes or a board write drops every
    [board:list:] entry. *)
