(** Runtime lane — ordered candidate list for keeper turn failover.

    [id] is the lane's own name, the [\[runtime.lanes.<name>\]] table key. It is
    chosen by the operator and carries no structure; a keeper assignment or a
    route id names it to walk the lane. Candidates are opaque runtime ids
    ("provider.model" binding keys).  The [Runtime] module resolves ids to
    materialized runtimes, keeping this module free of the [Runtime] dependency
    cycle. *)

type t =
  { id : string
  ; candidates : string list
  }

val make : id:string -> string list -> t
val id : t -> string
val ordered_candidates : t -> string list
