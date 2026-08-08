(** Bounded telemetry for canonical Keeper tool-name resolution. *)

val record_route_outcome :
  tool:string -> routed_to:string -> result:string -> unit
(** Record one route outcome. Unknown tool names are projected to a bounded
    [unknown] label instead of creating unbounded metric cardinality. *)
