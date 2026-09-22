(** H2 gateway response helpers. *)

val h2_respond_json :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  ?compress:bool ->
  H2.Reqd.t -> string -> unit

val h2_respond_json_value :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  ?compress:bool ->
  H2.Reqd.t -> Yojson.Safe.t -> unit

(** Encode immutable JSON on the shared CPU executor, then write on the
    caller fiber. Only the negotiated encoding is prepared. *)
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

val h2_read_body : H2.Reqd.t -> (string -> unit) -> unit
(** Reads the request body and hands the bytes read to the callback when the
    body reader reports end of input. h2 also reports end of input when it
    closes the reader because the stream failed, so a failed stream can hand
    the callback a partial body. A body over
    [Http_server_eio.Request.max_body_bytes], the HTTP/1 ceiling, is answered
    with 413 and the callback never runs. *)
