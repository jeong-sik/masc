(** H2 gateway response helpers. *)

val h2_respond_json
  :  ?status:H2.Status.t
  -> ?extra_headers:(string * string) list
  -> H2.Reqd.t
  -> string
  -> unit

val h2_respond_text
  :  ?status:H2.Status.t
  -> ?extra_headers:(string * string) list
  -> H2.Reqd.t
  -> string
  -> unit

val h2_respond_html
  :  ?status:H2.Status.t
  -> ?extra_headers:(string * string) list
  -> H2.Reqd.t
  -> string
  -> unit

val h2_respond_bytes
  :  ?status:H2.Status.t
  -> ?extra_headers:(string * string) list
  -> content_type:string
  -> H2.Reqd.t
  -> string
  -> unit

val h2_respond_empty
  :  ?status:H2.Status.t
  -> ?extra_headers:(string * string) list
  -> H2.Reqd.t
  -> unit

val h2_read_body : H2.Reqd.t -> (string -> unit) -> unit
