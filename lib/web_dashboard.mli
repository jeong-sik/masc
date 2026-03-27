(** MASC Web Dashboard - Real-time Agent Coordination Visualization *)

(** Resolve the static assets root used by both dashboard serving paths. *)
val assets_root : unit -> string

(** Generate the dashboard HTML page *)
val html : unit -> string

(** ETag for cache validation *)
val etag : unit -> string

(** Validate user-provided dashboard asset subpaths.
    Rejects absolute paths, parent traversal, and empty segments. *)
val is_safe_asset_relative_path : string -> bool
