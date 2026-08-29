(** MASC Web Dashboard - Real-time Agent Workspace Visualization *)

(** Resolve the static assets root used by both dashboard serving paths. *)
val assets_root : unit -> string option

(** Path to the dashboard build stamp ([<assets_root>/dashboard/.build-stamp]),
    touched by [scripts/build-dashboard-if-needed.sh] on every successful
    build. *)
val build_stamp_path : unit -> string option

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

(** Health projection of the dashboard surface for [/health]. [status] is
    ["ok"], ["stale"] (bundle predates the running binary), or ["missing"]
    (no build-stamp, unreadable stamp, or a stamp without [index.html]).
    Carries [assets_root], [build_stamp_path], [index_sha256], [index_present],
    a typed [recovery] action, and RFC3339 freshness timestamps when known. *)
val surface_status_json : unit -> Yojson.Safe.t

(** Generate the dashboard HTML page *)
val html : unit -> string

(** ETag for cache validation *)
val etag : unit -> string

(** Validate user-provided dashboard asset subpaths.
    Rejects absolute paths, parent traversal, and empty segments. *)
val is_safe_asset_relative_path : string -> bool

type asset_load_error =
  | Asset_binding_invalid of Build_identity.dashboard_asset_invalid_reason
  | Asset_build_unavailable
  | Asset_not_manifested
  | Asset_exact_read_failed of string

type recovery_reason =
  | Unbound_assets_missing
  | Unbound_assets_stale
  | Build_receipt_unavailable
  | Binding_invalid
  | Manifest_entry_missing
  | Exact_read_failed
  | Bound_assets_incomplete

type surface_recovery =
  | No_recovery
  | Build_in_place of recovery_reason
  | Restart_with_exact_build
  | Repair_exact_artifacts_and_restart of recovery_reason

val asset_error_http_status :
  asset_load_error -> [ `Not_found | `Service_unavailable ]

val load_dashboard_asset : string -> (string, asset_load_error) result
(** Load one dashboard-relative file. Provenance-bound launches read only the
    immutable content-addressed snapshot and verify size/SHA-256 before
    returning bytes. Invalid/replaced bindings fail closed. *)

module For_testing : sig
  val surface_recovery :
    asset_resolution:Build_identity.dashboard_asset_resolution ->
    loaded_index:(string, asset_load_error) result ->
    freshness:bundle_freshness ->
    surface_recovery

  val surface_recovery_json : surface_recovery -> Yojson.Safe.t

  val select_assets_root :
    launch_source_root_state:Build_identity.launch_source_root_state ->
    configured_assets_dir:string option ->
    exe_dir:string ->
    cwd:string ->
    is_dir:(string -> bool) ->
    string option
  (** Pure authority selection used by [assets_root]. A bound launch source
      always wins and does not fall back when its asset directory is absent. *)

  val load_and_verify_dashboard_blob :
    ?after_exact_read:(unit -> unit) ->
    snapshot_root:string ->
    expected_snapshot_device:int ->
    expected_snapshot_inode:int ->
    launch_source_root:string ->
    expected_source_device:int ->
    expected_source_inode:int ->
    string ->
    expected_size:int ->
    expected_sha256:string ->
    (string, asset_load_error) result
end
