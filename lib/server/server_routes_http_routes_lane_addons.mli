(** Optional Lane Add-on views and asynchronous lifecycle operations.
    Read handlers never wait for an observation worker. *)
val add_routes : sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> Http_server_eio.Router.t -> Http_server_eio.Router.t

val decode_body : string -> (Yojson.Safe.t, string) result
val decode_slice_query : (string * string) list -> (Yojson.Safe.t, string) result

val decode_inspect_query : (string * string) list -> (Yojson.Safe.t, string) result
