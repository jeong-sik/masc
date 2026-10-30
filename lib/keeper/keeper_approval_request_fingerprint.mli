(** Canonical identity for exact approval requests. *)

val request_fingerprint : Yojson.Safe.t -> string
(** SHA-256 of JSON with recursively sorted object fields. Array order and
    scalar values remain unchanged. *)
