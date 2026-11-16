(** The dispatch boundary for one share request. *)
type t
type ('a, 'refusal) result = Not_sent of 'refusal | Sent of ('a, string) Stdlib.result
val create : unit -> t
val dispatched : t -> bool
val perform : t -> preflight:(unit -> (unit, 'refusal) Stdlib.result) ->
  send:(unit -> ('a, string) Stdlib.result) -> ('a, 'refusal) result
(** A preflight refusal sends nothing and comes back as the caller typed it. The marker is set immediately before
    [send], without a yield in between. Once set, cancellation or an error
    cannot establish whether the server applied the operation. *)
