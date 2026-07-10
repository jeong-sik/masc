(** H2 gateway response helpers. *)

val httpun_headers_of_h2 : H2.Headers.t -> Httpun.Headers.t
(** Projects HTTP/2 request headers into the Httpun adapter contract. The
    required [:authority] pseudo-header is the SSOT for the synthesized [Host]
    header, so shared H1 Origin/auth helpers evaluate the real H2 authority. *)

val h2_respond_body :
  ?status:H2.Status.t ->
  ?extra_headers:(string * string) list ->
  ?compress:bool ->
  content_type:string ->
  H2.Reqd.t -> string -> unit

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

val h2_respond_removed_surface :
  H2.Reqd.t -> surface:string -> extra_headers:(string * string) list -> unit

val h2_read_body : H2.Reqd.t -> (string -> unit) -> unit
