(* An HTTP/1 answer from a [Dashboard_cache] payload.

   The body is the string the cache serialized when it filled the entry, so a
   repeat read neither serializes nor hashes the page again. The payload's
   [origin] says whether that string is a page or a timeout envelope, and the
   envelope goes out as 504 from that field, whatever its size: the string
   check [Http.Response.json_lazy] falls back on reads only bodies of 8 KB or
   less, and a key long enough to push an envelope past that went out as 200. *)

module Http = Http_server_eio

let respond ?(compress = true) ?(extra_headers = []) ~request reqd
    (payload : Dashboard_cache.cached_payload) =
  match payload.origin with
  | Dashboard_cache.Timeout ->
    Http.Response.json ~status:`Gateway_timeout ~compress ~extra_headers ~request
      payload.raw_json reqd
  | Dashboard_cache.Computed | Dashboard_cache.Seeded ->
    Http.Response.json_lazy ~compress ~extra_headers ~request ~etag:payload.etag
      (fun () -> payload.raw_json) reqd
;;
