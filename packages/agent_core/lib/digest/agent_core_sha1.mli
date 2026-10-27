(** SHA-1 fed in bounded slices (RFC-0474 L2). Kept only for the WebSocket
    handshake, whose RFC 6455 accept proof is defined over SHA-1. *)

val raw_digest_string : string -> string
(** The 20 raw digest bytes of the string. *)
