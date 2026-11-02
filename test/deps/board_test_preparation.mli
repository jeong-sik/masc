(** Explicit offline preparation of a caller-owned, existing and quiescent
    temporary BasePath, before constructing any Board store or backend. *)

type action = Bootstrap | Adopt

val prepare : base_path:string -> action:action -> unit
(** Inspect and perform exactly the requested action using its fresh intent.
    Return only when that invocation's [finish_outcome] is [Completed].
    Unexpected decisions (including Ready), absent intent and incomplete
    effects fail the fixture. Original reserved exceptions propagate.
    This neither acquires a host lease nor loads or admits a live store. *)
