(** Public Activity projections never inherit a caller's private Board access.
    Historic rows must still have a currently readable Public parent. *)
type t
type proof

val create : unit -> t
val keep : t -> Activity_graph.event -> bool
(** Decode the Board event family and check every recorded post/comment
    reference before paging. Historic Board tool telemetry
    with unproven raw I/O is excluded; unrelated activity is unchanged.
    Repeated references share one source-gated parent lookup per projection. *)

val proof : t -> proof
val is_current : proof -> bool
(** Recheck parents retained by a cached public projection. Missing parents or
    a refused source invalidate the cache; no Activity log is traversed. *)
