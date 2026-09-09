(** MASC Web Dashboard - Real-time Agent Workspace Visualization *)

(** Resolve the static assets root used by both dashboard serving paths. *)
val assets_root : unit -> string option

(** Path to the dashboard build stamp ([<assets_root>/dashboard/.build-stamp]),
    touched by [scripts/build-dashboard-if-needed.sh] on every successful
    build. *)
val build_stamp_path : unit -> string option

(** Source identity comparison, independently of file build times. A matching
    declaration does not certify an unbound asset tree's integrity. *)
type bundle_freshness =
  | Fresh
  | Mismatched of { dashboard_commit : string; binary_commit : string }
  | Unknown_identity

val bundle_freshness : unit -> bundle_freshness
val log_bundle_freshness_warning : unit -> unit

(** Health reports source mismatch, unknown provenance and missing assets
    separately. Bound manifests retain their integrity checks. *)
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
  | Asset_installed_invalid of Installed_dashboard.error
  | Asset_build_unavailable
  | Asset_not_manifested
  | Asset_exact_read_failed of string

type recovery_reason =
  | Unbound_assets_missing
  | Unbound_source_mismatch
  | Unbound_identity_unavailable
  | Build_receipt_unavailable
  | Binding_invalid
  | Manifest_entry_missing
  | Exact_read_failed
  | Bound_assets_incomplete

type surface_recovery =
  | No_recovery
  | Install_matching_ci_artifacts of recovery_reason
  | Restart_with_exact_build
  | Repair_exact_artifacts_and_restart of recovery_reason

val asset_error_http_status :
  asset_load_error -> [ `Not_found | `Service_unavailable ]

val load_dashboard_asset : string -> (string, asset_load_error) result
(** Load one dashboard-relative file. Provenance-bound launches read only the
    immutable content-addressed snapshot and verify size/SHA-256 before
    returning bytes. Invalid/replaced bindings fail closed. *)

module For_testing : sig
  val surface_status_json :
    ?binary_commit:string option -> Installed_dashboard.selection -> Yojson.Safe.t
  (** Health projection with an explicit, already selected installed authority.
      Performs the real asset and receipt checks afresh on every call. *)

  val select_installed_authority :
    launch_source_root_state:Build_identity.launch_source_root_state ->
    installed:Installed_dashboard.selection -> Installed_dashboard.selection
  (** Explicit source bindings, including invalid ones, take precedence. *)

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
