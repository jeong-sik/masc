(** Download and endpoint checks shared by the live browser connections. *)
val verify_file : root:string -> string -> (string * int, string) result

(** Validate a loopback WebSocket endpoint without connecting. Any string is
    answered: one that is no address is an [Error], not an exception. *)
val endpoint : string -> (string * int * string, string) result

(** {!endpoint}, with the address as it was parsed. *)
val endpoint_uri : string -> (Uri.t * (string * int * string), string) result
