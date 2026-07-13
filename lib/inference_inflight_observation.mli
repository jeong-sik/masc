(** MASC-visible observation of inference calls.

    This boundary never admits, rejects, ranks, queues, or delays a Keeper.
    Provider capacity, retry, and throttling belong to OAS. *)

val with_observation :
  keeper_name:string -> runtime_id:string -> (unit -> 'a) -> 'a
(** Run the callback while recording one active inference call. *)

val active : unit -> int
(** Number of callbacks currently crossing the OAS boundary. *)

val snapshot_json : unit -> Yojson.Safe.t
(** Exact observation payload.  It contains no configured or inferred
    capacity because MASC does not own provider capacity. *)

module For_testing : sig
  val reset : unit -> unit
end
