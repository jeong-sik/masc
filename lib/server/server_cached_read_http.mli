(** An answer from a {!Dashboard_cache.cached_payload} or prepared JSON
    response on either transport. *)

type prepared_http
(** Pre-serialized JSON payload carrying its weak entity tag and pre-encoded
    identity/zstd/gzip representations so repeat HTTP reads never re-serialize,
    hash, or submit compression to the CPU pool. Timeout envelopes
    ({!Dashboard_cache.is_timeout_envelope}) are detected at preparation time
    and sent as 504 without an entity tag. *)

val prepare_json_string : string -> prepared_http
(** [prepare_json_string raw] computes the weak entity tag and prepares
    identity/zstd/gzip representations for [raw]. *)

val prepare_json : Yojson.Safe.t -> prepared_http
(** [prepare_json json] serializes [json] once and prepares its HTTP
    representations. *)

val respond_prepared :
  ?extra_headers:(string * string) list ->
  request:Httpun.Request.t ->
  Http_reqd.t ->
  prepared_http ->
  unit
(** [respond_prepared ~request reqd prepared] selects the matching pre-encoded
    representation in O(1) without compression and answers a matching
    [If-None-Match] with 304. *)

val respond_prepared_status :
  status:Httpun.Status.t ->
  ?extra_headers:(string * string) list ->
  request:Httpun.Request.t ->
  Http_reqd.t ->
  prepared_http ->
  unit
(** Like {!respond_prepared}, using an explicit HTTP status (e.g. 503
    readiness) without recompressing on the CPU pool. *)

val respond :
  ?compress:bool ->
  ?extra_headers:(string * string) list ->
  request:Httpun.Request.t ->
  Http_reqd.t ->
  Dashboard_cache.cached_payload ->
  unit
(** [respond ~request reqd payload] sends [payload.raw_json], the string the
    cache serialized with the entry, under [payload.etag], answering a matching
    [If-None-Match] with 304. When [payload.json] is a timeout envelope
    ({!Dashboard_cache.is_timeout_envelope}) it goes out as 504 without a
    validator, whatever its size and whether the cache or the builder produced
    it. [compress] (default [true]) reuses encodings prepared in
    [payload.encoded] when available, otherwise compresses for a client that
    accepts an encoding. *)
