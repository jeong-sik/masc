(* An answer from a [Dashboard_cache] payload on either transport.

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

type prepared_http =
  | Ready_prepared of {
      etag : string;
      encoded : Http_response_payload.prepared;
    }
  | Timeout_prepared of string

let prepare_json_string raw =
  Ready_prepared
    { etag = Http.Response.weak_etag_value raw
    ; encoded = Http_response_payload.prepare raw
    }

let prepare_json json =
  let raw = Yojson.Safe.to_string json in
  if Dashboard_cache.is_timeout_envelope json then
    Timeout_prepared raw
  else
    prepare_json_string raw

let respond_prepared ?(extra_headers = []) ~request reqd = function
  | Timeout_prepared raw ->
    Http.Response.json ~status:`Gateway_timeout ~compress:false ~extra_headers
      ~request raw reqd
  | Ready_prepared { etag; encoded } ->
    let accept_encoding =
      Http_response_payload.accept_encoding_fields
        (Httpun.Headers.get_multi request.Httpun.Request.headers "accept-encoding")
    in
    let body, encoding_headers =
      Http_response_payload.select_prepared ~accept_encoding encoded
    in
    Http.Response.json_lazy ~compress:false ~request ~etag
      ~extra_headers:(encoding_headers @ extra_headers) (fun () -> body) reqd

let respond_prepared_status ~status ?(extra_headers = []) ~request reqd = function
  | Timeout_prepared raw ->
    Http.Response.json ~status:`Gateway_timeout ~compress:false ~extra_headers
      ~request raw reqd
  | Ready_prepared { etag = _; encoded } ->
    let accept_encoding =
      Http_response_payload.accept_encoding_fields
        (Httpun.Headers.get_multi request.Httpun.Request.headers "accept-encoding")
    in
    let body, encoding_headers =
      Http_response_payload.select_prepared ~accept_encoding encoded
    in
    Http.Response.json ~status ~compress:false
      ~extra_headers:(encoding_headers @ extra_headers) ~request body reqd

let respond ?(compress = true) ?(extra_headers = []) ~request reqd
    (payload : Dashboard_cache.cached_payload) =
  if Dashboard_cache.is_timeout_envelope payload.json
  then
    Http.Response.json ~status:`Gateway_timeout ~compress ~extra_headers ~request
      payload.raw_json reqd
  else if compress && Option.is_some payload.encoded
  then
    let accept_encoding =
      Http_response_payload.accept_encoding_fields
        (Httpun.Headers.get_multi request.Httpun.Request.headers "accept-encoding")
    in
    let body, encoding_headers =
      Dashboard_cache.select_http_representation ~accept_encoding payload
    in
    Http.Response.json_lazy ~compress:false ~request ~etag:payload.etag
      ~extra_headers:(encoding_headers @ extra_headers) (fun () -> body) reqd
  else
    Http.Response.json ~compress ~extra_headers ~request ~etag:payload.etag
      payload.raw_json reqd
;;
