(** An HTTP/1 answer from a {!Dashboard_cache.cached_payload}. *)

val respond :
  ?compress:bool ->
  ?extra_headers:(string * string) list ->
  request:Httpun.Request.t ->
  Httpun.Reqd.t ->
  Dashboard_cache.cached_payload ->
  unit
(** [respond ~request reqd payload] sends [payload.raw_json], the string the
    cache serialized with the entry, under [payload.etag], answering a matching
    [If-None-Match] with 304. A payload whose [origin] is [Timeout] goes out as
    504 without a validator. [compress] (default [true]) compresses the body
    for a client that accepts an encoding, as {!Http.Response.json_lazy} does. *)
