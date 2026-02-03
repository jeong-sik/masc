(** MASC Web Dashboard - Real-time Agent Coordination Visualization *)

(** Generate the dashboard HTML page *)
val html : unit -> string

(** ETag for cache validation *)
val etag : unit -> string
