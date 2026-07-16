(** MASC Web Dashboard - Real-time Agent Workspace Visualization *)

(** Resolve the static assets root used by both dashboard serving paths. *)
val assets_root : unit -> string

(** Path to the dashboard build stamp ([<assets_root>/dashboard/.build-stamp]),
    touched by [scripts/build-dashboard-if-needed.sh] on every successful
    build. *)
val build_stamp_path : unit -> string

(** Result of comparing the served bundle's build-stamp mtime against the
    running server binary's mtime. [Missing_stamp] covers both "never built"
    and any stat failure on the stamp path. *)
type bundle_freshness =
  | Fresh
  | Stale of { stamp_mtime : float; binary_mtime : float }
  | Missing_stamp

(** Compare the dashboard bundle's build-stamp mtime against the running
    server binary's mtime. See {!log_bundle_freshness_warning} for the
    boot-time WARN this backs. *)
val bundle_freshness : unit -> bundle_freshness

(** Log a boot-time WARN via [Log.Dashboard.warn] when the served dashboard
    bundle is stale (predates the running binary) or its build-stamp is
    missing/unreadable. A no-op when the bundle is fresh. Call once during
    server startup. *)
val log_bundle_freshness_warning : unit -> unit

(** Generate the dashboard HTML page *)
val html : unit -> string

(** ETag for cache validation *)
val etag : unit -> string

(** Validate user-provided dashboard asset subpaths.
    Rejects absolute paths, parent traversal, and empty segments. *)
val is_safe_asset_relative_path : string -> bool
