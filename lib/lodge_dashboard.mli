(** MASC Lodge Selection Dashboard - Thompson Sampling Statistics

    HTTP endpoint: /dashboard/lodge *)

(** ETag for caching *)
val etag : unit -> string

(** Generate the dashboard HTML page *)
val html : unit -> string
