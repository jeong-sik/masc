(** Relay envelope: [[4B big-endian peer id][payload]] (RFC-0471 §2.3).

    Host to relay uses peer 0 to broadcast to every guest, or peer N to
    target guest N. Guest to relay always uses peer 0; the relay rewrites it
    to the sender's id. The payload is opaque sealed bytes (see
    {!Collab_seal}). *)

val header_length : int
(** [4]. Envelope header size in bytes. *)

val broadcast_peer : int
(** [0]. Broadcast peer id. *)

val max_peer : int
(** [0xFFFFFFFF]. Largest encodable peer id. *)

type pack_error = Peer_id_out_of_range of int

val pack : peer:int -> string -> (string, pack_error) result
(** [pack ~peer payload] prefixes [payload] with the 4-byte header. A [peer]
    outside [0..max_peer] is an [Error]; it is never masked or wrapped. *)

val unpack : string -> (int * string) option
(** [unpack bytes] splits the header from the payload. [None] iff [bytes] is
    shorter than {!header_length}. *)
