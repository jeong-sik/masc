(** The dispatch boundary for one share request. *)
type t
type 'a result = Not_sent of string | Sent of ('a, string) Stdlib.result
val create : unit -> t
val dispatched : t -> bool
val perform : t -> preflight:(unit -> (unit, string) Stdlib.result) ->
  send:(unit -> ('a, string) Stdlib.result) -> 'a result
(** A preflight refusal sends nothing. The marker is set immediately before
    [send], without a yield in between. Once set, cancellation or an error
    cannot establish whether the server applied the operation. *)
