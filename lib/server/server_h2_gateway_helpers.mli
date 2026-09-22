(** H2 gateway response helpers. *)

(** [h2_close_after_flush writer] closes [writer] once every byte written to it
    so far has been handed to the connection, not right away. Close a body
    that may still hold unsent bytes with this, never with
    [H2.Body.Writer.close]: h2 0.13.0 cuts such a body at the client's
    flow-control window (anmonteiro/ocaml-h2#278). *)
val h2_close_after_flush : H2.Body.Writer.t -> unit

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
