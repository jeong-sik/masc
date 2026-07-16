(** Process-wide Mirage Crypto RNG initialization boundary. *)

val ensure_default : unit -> unit
(** Ensure that Mirage Crypto has a process-wide default generator. *)

val generate : int -> string
(** [generate bytes] returns [bytes] from the operating system's cryptographic
    random source. *)
