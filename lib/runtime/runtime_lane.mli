(** Runtime lane — ordered candidate list for keeper turn failover.

    Candidates are opaque runtime ids ("provider.model" binding keys).  The
    [Runtime] module resolves ids to materialized runtimes, keeping this module
    free of the [Runtime] dependency cycle. *)

type strategy = Ordered

type t =
  { id : string
  ; strategy : strategy
  ; candidates : string list
  }

val make : id:string -> strategy:strategy -> string list -> t
val id : t -> string
val strategy : t -> strategy
val ordered_candidates : t -> string list
