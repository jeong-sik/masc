(** The highest number recorded under each name, kept for the life of the
    process. Recording a number below the one held changes nothing, so
    recordings that finish out of order leave the highest in place. Safe to
    record from several domains at once. *)

type t

val create : unit -> t

val raise_to : t -> string -> int -> unit
(** [raise_to t name n] holds [n] under [name] unless a number at least as
    high is held already. *)

val find : t -> string -> int option
