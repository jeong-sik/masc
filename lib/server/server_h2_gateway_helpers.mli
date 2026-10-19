(** H2 gateway response helpers. Application responses require the request
    context installed by {!Server_bootstrap_http} or {!Server_h2_gateway}.
    A whole payload that exceeds the listener's available capacity receives
    an empty 503 before success headers are sent. Accepted payloads retain
    their reservation until flush or request-scope cleanup. *)

val dispatch_request :
  sw:Eio.Switch.t -> H2.Reqd.t -> (unit -> unit) -> unit
(** Schedule deferred request work on [sw], the request stream's switch. The callback
    yields before running, keeps transport access on this domain, and reports
    handler exceptions to its own stream. Cancellation propagates. *)

(** [h2_close_after_flush writer] closes [writer] once every byte written to it
    so far has been handed to the connection, not right away. Close an H2
    response body with this, never with [H2.Body.Writer.close]: h2 0.13.0 cuts
    a closed body at the client's flow-control window
    (anmonteiro/ocaml-h2#278).

    Write the whole body first. Bytes written after this call are cut the same
    way, because the flush only covers the bytes already written. *)
val h2_close_after_flush : H2.Body.Writer.t -> unit

val h2_respond_json :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  ?compress:bool ->
  H2.Reqd.t -> string -> unit

(** [payload.raw_json], the string the cache serialized with the entry: 200
    for a page, 504 when [payload.json] is a timeout envelope
    ({!Dashboard_cache.is_timeout_envelope}), whether the cache or the builder
    produced it. The body is compressed
    per request as {!h2_respond_json} does; encodings prepared in
    [payload.encoded] are not used, so a payload prepared with them goes
    through {!Dashboard_cache.select_http_representation} instead. *)
val h2_respond_cached_payload :
  ?extra_headers:(string * string) list ->
  H2.Reqd.t -> Dashboard_cache.cached_payload -> unit

(** JSON values use the HTTP/1 timeout-envelope status rule: the default or
    explicit 200 becomes 504 for an envelope; other explicit statuses remain.
    The envelope body and response headers are preserved. *)
val h2_respond_json_value :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  ?compress:bool ->
  H2.Reqd.t -> Yojson.Safe.t -> unit

(** Encode immutable JSON on the shared CPU executor, then write on the
    caller fiber. Only the negotiated encoding is prepared. Timeout status
    follows {!h2_respond_json_value}, including when no pool is installed. *)
val h2_respond_json_value_on_cpu :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  ?compress:bool ->
  H2.Reqd.t -> Yojson.Safe.t -> unit

val h2_respond_text :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  H2.Reqd.t -> string -> unit

val h2_respond_html :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  H2.Reqd.t -> string -> unit

val h2_respond_bytes :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  ?compress:bool ->
  content_type:string ->
  H2.Reqd.t -> string -> unit

val h2_respond_empty :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  H2.Reqd.t -> unit

val h2_read_body_with_limit :
  sw:Eio.Switch.t ->
  max_bytes:int ->
  on_too_large:(unit -> unit) ->
  on_bad_request:(unit -> unit) ->
  H2.Reqd.t -> (string -> unit) -> unit
(** Deliver a valid, complete body within the route's HTTP size limit.
    A declared or streamed excess discards the reader and schedules
    [on_too_large]; malformed length schedules [on_bad_request]. Completion
    and refusal callbacks run through [dispatch_request]. Completion is
    checked again after deferral, so an intervening error or reset cannot
    deliver a partial body. Aborted readers never reach the body callback. *)

val h2_read_body : sw:Eio.Switch.t -> H2.Reqd.t -> (string -> unit) -> unit
(** {!h2_read_body_with_limit} with the HTTP/1 body ceiling, a 413 response for
    excess and a 400 response for malformed length. *)
