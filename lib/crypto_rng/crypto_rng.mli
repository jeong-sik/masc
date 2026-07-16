(** Process-wide Mirage Crypto RNG initialization and generation boundary. *)

val ensure_default : unit -> unit
(** Ensure that Mirage Crypto has a process-wide default generator. *)

val generate : int -> string
(** [generate bytes] returns [bytes] cryptographically random bytes using the
    generator obtained from the process-wide default boundary. Calls are
    serialized because the generator is not safe for concurrent use. *)
