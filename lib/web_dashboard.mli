(** MASC Web Dashboard - Real-time Agent Coordination Visualization *)

(** Resolve the assets root directory.
    Probes MASC_ASSETS_DIR, MASC_BASE_PATH_INPUT/assets, MASC_BASE_PATH/assets,
    exe-relative, and cwd-relative candidates. *)
val assets_root : unit -> string

(** Generate the dashboard HTML page *)
val html : unit -> string

(** ETag for cache validation *)
val etag : unit -> string

(** Validate user-provided dashboard asset subpaths.
    Rejects absolute paths, parent traversal, and empty segments. *)
val is_safe_asset_relative_path : string -> bool
