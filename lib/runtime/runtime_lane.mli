(** Runtime lane — ordered candidate list for keeper turn failover.

    Candidates are opaque runtime ids ("provider.model" binding keys).  The
    [Runtime] module resolves ids to materialized runtimes, keeping this module
    free of the [Runtime] dependency cycle. *)

type t =
  { id : string
  ; candidates : string list
  ; declared_candidates : string list
  }

val make : id:string -> string list -> t
val id : t -> string
val ordered_candidates : t -> string list
val declared_candidates : t -> string list
(** Frozen declared candidates, excluding any implicit terminal default. *)
val with_terminal_default : runtime_id:string -> t -> t
(** Extend ordinary routing without widening the declared authority view. *)
val filter_candidates : (string -> bool) -> t -> t
(** Remove unavailable candidates from both views, preserving their order. *)
