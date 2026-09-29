(* An HTTP/1 answer from a [Dashboard_cache] payload.

   The body is the string the cache serialized when it filled the entry, and
   the validator is the entity tag it computed then, so a repeat read neither
   serializes, hashes nor parses the page.

   A timeout envelope goes out as 504. The envelope is recognized from the
   payload's JSON with [Dashboard_cache.is_timeout_envelope], not from its
   [origin]: a builder with a shorter ceiling of its own can return the
   envelope as its value, and the cache then keeps it as a computed page. The
   check reads the top-level fields of the kept JSON, so it holds at any size;
   the string check [Http.Response.json_lazy] makes parses only bodies of 8 KB
   or less. *)

module Http = Http_server_eio

let respond ?(compress = true) ?(extra_headers = []) ~request reqd
    (payload : Dashboard_cache.cached_payload) =
  if Dashboard_cache.is_timeout_envelope payload.json
  then
    Http.Response.json ~status:`Gateway_timeout ~compress ~extra_headers ~request
      payload.raw_json reqd
  else
    Http.Response.json ~compress ~extra_headers ~request ~etag:payload.etag
      payload.raw_json reqd
;;
