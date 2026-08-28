(** MASC Web Dashboard — SPA (Preact + HTM)

    The dashboard is now a TypeScript SPA built with Vite.
    Source: dashboard/src/
    Build output: assets/dashboard/

    This module is kept for backward compatibility.
    The actual serving logic is in bin/main_eio.ml (serve_dashboard_index).
*)

let select_assets_root
      ~launch_source_root_state
      ~configured_assets_dir
      ~exe_dir
      ~cwd
      ~is_dir
  =
  let inferred_repo_assets =
    let root = Filename.dirname (Filename.dirname (Filename.dirname exe_dir)) in
    Filename.concat root "assets"
  in
  (* MASC_BASE_PATH is the runtime data root for .masc, not a dashboard asset root. *)
  let candidates =
    List.fold_right
      (fun path acc ->
        match path with
        | Some value -> value :: acc
        | None -> acc)
      [
        Some inferred_repo_assets;
        Some (Filename.concat exe_dir "assets");
        Some (Filename.concat cwd "assets");
      ]
      []
  in
  match launch_source_root_state with
  | Build_identity.Bound_valid source_root -> Some (Filename.concat source_root "assets")
  | Build_identity.Bound_invalid _ -> None
  | Build_identity.Unbound ->
    (match configured_assets_dir with
     | Some d when is_dir d -> Some d
     | _ ->
      match List.find_opt is_dir candidates with
      | Some path -> Some path
      | None ->
        (match candidates with
         | path :: _ -> Some path
         | [] -> Some (Filename.concat cwd "assets")))
;;

let assets_root () =
  let is_dir path =
    try (Unix.stat path).Unix.st_kind = Unix.S_DIR with
    | Unix.Unix_error _ -> false
  in
  select_assets_root
    ~launch_source_root_state:(Build_identity.launch_source_root_state ())
    ~configured_assets_dir:(Host_config.from_env ()).assets_dir
    ~exe_dir:(Filename.dirname Sys.executable_name)
    ~cwd:(Config_dir_resolver.current_working_dir ())
    ~is_dir
;;

let build_stamp_path () =
  match Build_identity.resolve_dashboard_asset ".build-stamp" with
  | Build_identity.Dashboard_asset_bound { path; _ } -> Some path
  | Build_identity.Dashboard_assets_unbound ->
    Option.map
      (fun root -> Filename.concat (Filename.concat root "dashboard") ".build-stamp")
      (assets_root ())
  | Build_identity.Dashboard_assets_invalid _
  | Build_identity.Dashboard_assets_unavailable
  | Build_identity.Dashboard_asset_not_manifested -> None

let mtime_of path =
  try Some (Unix.stat path).Unix.st_mtime with
  | Unix.Unix_error _ -> None

type asset_load_error =
  | Asset_binding_invalid of Build_identity.dashboard_asset_invalid_reason
  | Asset_build_unavailable
  | Asset_not_manifested
  | Asset_exact_read_failed of string

let asset_error_http_status = function
  | Asset_not_manifested -> `Not_found
  | Asset_binding_invalid _
  | Asset_build_unavailable
  | Asset_exact_read_failed _ -> `Service_unavailable
;;

let snapshot_root_matches ~snapshot_root ~expected_device ~expected_inode =
  try
    let canonical = Unix.realpath snapshot_root in
    let info = Unix.stat canonical in
    String.equal canonical snapshot_root
    && info.st_kind = Unix.S_DIR
    && info.st_uid = Unix.geteuid ()
    && info.st_perm = 0o700
    && info.st_dev = expected_device
    && info.st_ino = expected_inode
  with
  | Sys_error _ | Unix.Unix_error _ -> false
;;

let source_root_matches ~source_root ~expected_device ~expected_inode =
  try
    let canonical = Unix.realpath source_root in
    let info = Unix.stat canonical in
    String.equal canonical source_root
    && info.st_kind = Unix.S_DIR
    && info.st_uid = Unix.geteuid ()
    && info.st_dev = expected_device
    && info.st_ino = expected_inode
  with
  | Sys_error _ | Unix.Unix_error _ -> false
;;

let load_and_verify_dashboard_blob
      ?(after_exact_read = fun () -> ())
      ~snapshot_root
      ~expected_snapshot_device
      ~expected_snapshot_inode
      ~launch_source_root
      ~expected_source_device
      ~expected_source_inode
      path
      ~expected_size
      ~expected_sha256
  =
  let root_matches () =
    snapshot_root_matches
      ~snapshot_root
      ~expected_device:expected_snapshot_device
      ~expected_inode:expected_snapshot_inode
  in
  let source_matches () =
    source_root_matches
      ~source_root:launch_source_root
      ~expected_device:expected_source_device
      ~expected_inode:expected_source_inode
  in
  if not (source_matches ())
  then Error (Asset_exact_read_failed "dashboard launch source root identity differs")
  else if not (root_matches ())
  then Error (Asset_exact_read_failed "dashboard snapshot root identity differs")
  else
  match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:snapshot_root path with
  | Error _ -> Error (Asset_exact_read_failed "dashboard snapshot exact read failed")
  | Ok None -> Error (Asset_exact_read_failed "manifested dashboard blob is missing")
  | Ok (Some contents) ->
    after_exact_read ();
    let body = contents.content in
    let actual_sha256 = Digestif.SHA256.(digest_string body |> to_hex) in
    if not (source_matches ())
    then Error (Asset_exact_read_failed "dashboard launch source root identity changed")
    else if not (root_matches ())
    then Error (Asset_exact_read_failed "dashboard snapshot root identity changed")
    else if String.length body <> expected_size
    then Error (Asset_exact_read_failed "dashboard asset size differs from launch manifest")
    else if not (String.equal actual_sha256 expected_sha256)
    then Error (Asset_exact_read_failed "dashboard asset digest differs from launch manifest")
    else Ok body
;;

let load_dashboard_asset relative_path =
  match Build_identity.resolve_dashboard_asset relative_path with
  | Build_identity.Dashboard_asset_bound
      { path
      ; launch_source_root
      ; launch_source_device
      ; launch_source_inode
      ; expected_size
      ; expected_sha256
      ; snapshot_root
      ; snapshot_device
      ; snapshot_inode
      ; _
      } ->
    load_and_verify_dashboard_blob
      ~snapshot_root
      ~expected_snapshot_device:snapshot_device
      ~expected_snapshot_inode:snapshot_inode
      ~launch_source_root
      ~expected_source_device:launch_source_device
      ~expected_source_inode:launch_source_inode
      path
      ~expected_size
      ~expected_sha256
  | Build_identity.Dashboard_assets_unbound ->
    (match assets_root () with
     | None -> Error (Asset_exact_read_failed "dashboard asset root unavailable")
     | Some root ->
       let path = Filename.concat (Filename.concat root "dashboard") relative_path in
       if not (Sys.file_exists path)
       then Error Asset_not_manifested
       else
         (try Ok (Fs_compat.load_file path) with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Asset_exact_read_failed (Printexc.to_string exn))))
  | Build_identity.Dashboard_assets_invalid reason ->
    Error (Asset_binding_invalid reason)
  | Build_identity.Dashboard_assets_unavailable ->
    Error Asset_build_unavailable
  | Build_identity.Dashboard_asset_not_manifested ->
    Error Asset_not_manifested
;;

let dashboard_asset_root () =
  match Build_identity.resolve_dashboard_asset "index.html" with
  | Build_identity.Dashboard_asset_bound { snapshot_root; _ } -> Some snapshot_root
  | Build_identity.Dashboard_assets_unbound ->
    Option.map (fun root -> Filename.concat root "dashboard") (assets_root ())
  | Build_identity.Dashboard_assets_invalid _
  | Build_identity.Dashboard_assets_unavailable
  | Build_identity.Dashboard_asset_not_manifested -> None
;;

let iso8601_of_unix_seconds = Time_codec.rfc3339_of_unix

type bundle_freshness =
  | Fresh
  | Stale of { stamp_mtime : float; binary_mtime : float }
  | Missing_stamp

(** Compare the dashboard bundle's [.build-stamp] mtime (touched by
    [scripts/build-dashboard-if-needed.sh] on every successful build) against
    the running server binary's mtime. A stamp older than the binary means a
    new server was shipped without rebuilding the SPA — the exact drift that
    let a removed HTTP route (#24332) keep getting called by a still-stale
    bundle. [Missing_stamp] covers both "never built" and any stat failure on
    the stamp path, so a broken assets_root resolution is never silently
    treated as fresh. *)
let bundle_freshness () =
  match Build_identity.resolve_dashboard_asset "index.html" with
  | Build_identity.Dashboard_asset_bound _ ->
    (match Build_identity.resolve_dashboard_asset ".build-stamp" with
     | Build_identity.Dashboard_asset_bound _ -> Fresh
     | _ -> Missing_stamp)
  | Build_identity.Dashboard_assets_invalid _
  | Build_identity.Dashboard_assets_unavailable
  | Build_identity.Dashboard_asset_not_manifested -> Missing_stamp
  | Build_identity.Dashboard_assets_unbound ->
    (match Option.bind (build_stamp_path ()) mtime_of with
     | None -> Missing_stamp
     | Some stamp_mtime ->
    (match mtime_of Sys.executable_name with
     | None ->
       (* Can't stat our own binary (unusual, e.g. exec'd via a symlink the
          OS deleted from under us) — nothing to compare against, so this is
          not evidence of staleness either way. *)
       Fresh
     | Some binary_mtime ->
       if stamp_mtime < binary_mtime then Stale { stamp_mtime; binary_mtime }
       else Fresh))

(** Log a boot-time WARN when the served bundle is stale or missing. Never
    silent: a missing stamp warns just as loudly as a stale one. Intended to
    be called once during server startup (see
    Server_runtime_bootstrap.run). *)
let log_bundle_freshness_warning () =
  match bundle_freshness () with
  | Fresh -> ()
  | Missing_stamp ->
    Log.Dashboard.warn
      "bundle build-stamp unavailable at %s — dashboard assets may be missing \
       or unbuilt; inspect /health dashboard_surface.recovery"
      (Option.value ~default:"<bound-dashboard-unavailable>" (build_stamp_path ()))
  | Stale { stamp_mtime; binary_mtime } ->
    Log.Dashboard.warn
      "bundle build-stamp %s older than server binary %s — inspect /health \
       dashboard_surface.recovery"
      (iso8601_of_unix_seconds stamp_mtime)
      (iso8601_of_unix_seconds binary_mtime)

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

let surface_recovery
      ~asset_resolution
      ~loaded_index
      ~freshness
  =
  match asset_resolution with
  | Build_identity.Dashboard_assets_unbound ->
    (match loaded_index, freshness with
     | Ok _, Fresh -> No_recovery
     | Error _, Fresh -> Build_in_place Unbound_assets_missing
     | _, Stale _ -> Build_in_place Unbound_assets_stale
     | _, Missing_stamp -> Build_in_place Unbound_assets_missing)
  | Build_identity.Dashboard_assets_unavailable -> Restart_with_exact_build
  | Build_identity.Dashboard_assets_invalid _ ->
    Repair_exact_artifacts_and_restart Binding_invalid
  | Build_identity.Dashboard_asset_not_manifested ->
    Repair_exact_artifacts_and_restart Manifest_entry_missing
  | Build_identity.Dashboard_asset_bound _ ->
    (match loaded_index, freshness with
     | Ok _, Fresh -> No_recovery
     | Error (Asset_binding_invalid _), _ ->
       Repair_exact_artifacts_and_restart Binding_invalid
     | Error Asset_not_manifested, _ ->
       Repair_exact_artifacts_and_restart Manifest_entry_missing
     | Error (Asset_exact_read_failed _), _ ->
       Repair_exact_artifacts_and_restart Exact_read_failed
     | Error Asset_build_unavailable, _ -> Restart_with_exact_build
     | Ok _, (Missing_stamp | Stale _) ->
       Repair_exact_artifacts_and_restart Bound_assets_incomplete)
;;

let recovery_reason_string = function
  | Unbound_assets_missing -> "unbound_assets_missing"
  | Unbound_assets_stale -> "unbound_assets_stale"
  | Build_receipt_unavailable -> "build_receipt_unavailable"
  | Binding_invalid -> "binding_invalid"
  | Manifest_entry_missing -> "manifest_entry_missing"
  | Exact_read_failed -> "exact_read_failed"
  | Bound_assets_incomplete -> "bound_assets_incomplete"
;;

let surface_recovery_json = function
  | No_recovery ->
    `Assoc
      [ "kind", `String "none"
      ; "reason", `String "surface_ready"
      ; "restart_required", `Bool false
      ]
  | Build_in_place reason ->
    `Assoc
      [ "kind", `String "build_in_place"
      ; "reason", `String (recovery_reason_string reason)
      ; "restart_required", `Bool false
      ]
  | Restart_with_exact_build ->
    `Assoc
      [ "kind", `String "restart_with_exact_build"
      ; "reason", `String (recovery_reason_string Build_receipt_unavailable)
      ; "restart_required", `Bool true
      ]
  | Repair_exact_artifacts_and_restart reason ->
    `Assoc
      [ "kind", `String "repair_exact_artifacts_and_restart"
      ; "reason", `String (recovery_reason_string reason)
      ; "restart_required", `Bool true
      ]
;;

(** Health projection of the dashboard surface. The boot-time WARN from
    {!log_bundle_freshness_warning} scrolls away with the log ring; this JSON
    keeps the same verdict visible on every [/health] probe, so an operator
    (or an audit) can see a dark dashboard surface without replaying startup
    logs. [status] is ["ok"], ["stale"], or ["missing"]; a present build-stamp
    with no [index.html] still reports ["missing"] because the index is what
    actually serves. *)
let surface_status_json () =
  let asset_resolution = Build_identity.resolve_dashboard_asset "index.html" in
  let manifest_identity = Build_identity.dashboard_manifest_identity () in
  let loaded_index = load_dashboard_asset "index.html" in
  let freshness = bundle_freshness () in
  let index_present = Result.is_ok loaded_index in
  let bound_invalid =
    match asset_resolution with
    | Build_identity.Dashboard_assets_invalid _
    | Build_identity.Dashboard_assets_unavailable -> true
    | Build_identity.Dashboard_assets_unbound
    | Build_identity.Dashboard_asset_not_manifested
    | Build_identity.Dashboard_asset_bound _ -> false
  in
  let freshness_status, freshness_fields =
    match freshness with
    | Missing_stamp -> ("missing", [])
    | Stale { stamp_mtime; binary_mtime } ->
      ( "stale"
      , [ ("build_stamp_at", `String (iso8601_of_unix_seconds stamp_mtime))
        ; ("binary_built_at", `String (iso8601_of_unix_seconds binary_mtime))
        ] )
    | Fresh ->
      let stamp_field =
        match Option.bind (build_stamp_path ()) mtime_of with
        | Some stamp_mtime ->
          [ ("build_stamp_at", `String (iso8601_of_unix_seconds stamp_mtime)) ]
        | None -> []
      in
      ("ok", stamp_field)
  in
  (* A missing index.html trumps freshness: the index is what actually
     serves, so a stale-or-fresh stamp without it is still a dark surface. *)
  let status =
    if bound_invalid then "unavailable"
    else if index_present then freshness_status
    else "missing"
  in
  let recovery = surface_recovery ~asset_resolution ~loaded_index ~freshness in
  `Assoc
    ([ ("schema", `String "masc.dashboard_surface.v1")
     ; ("status", `String status)
     ; ("index_present", `Bool index_present)
     ; ("assets_root", Json_util.string_opt_to_json (assets_root ()))
     ; ("dashboard_asset_root", Json_util.string_opt_to_json (dashboard_asset_root ()))
     ; ( "dashboard_manifest_root"
       , Json_util.string_opt_to_json
           (Option.map
              (fun (manifest : Build_identity.dashboard_assets_provenance) ->
                manifest.snapshot_root)
              manifest_identity) )
     ; ("build_stamp_path", Json_util.string_opt_to_json (build_stamp_path ()))
     ; ( "index_sha256"
       , Json_util.string_opt_to_json
           (match loaded_index with
            | Ok body -> Some Digestif.SHA256.(digest_string body |> to_hex)
            | Error _ -> None) )
     ; ( "asset_tree_sha256"
       , (match manifest_identity with
          | Some manifest -> `String manifest.tree_sha256
          | _ -> `Null) )
     ; ( "asset_file_count"
       , (match manifest_identity with
          | Some manifest -> `Int (List.length manifest.files)
          | _ -> `Null) )
     ; ( "build_input_sha256"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_input_sha256
          | _ -> `Null) )
     ; ( "build_source_commit"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_source_commit
          | _ -> `Null) )
     ; ( "build_head_tree"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_head_tree
          | _ -> `Null) )
     ; ( "build_index_tree"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_index_tree
          | _ -> `Null) )
     ; ( "build_input_file_count"
       , (match manifest_identity with
          | Some manifest -> `Int manifest.build_input_file_count
          | _ -> `Null) )
     ; ( "build_input_matches_head"
       , (match manifest_identity with
          | Some manifest -> `Bool manifest.build_input_matches_head
          | _ -> `Null) )
     ; ( "build_lock_sha256"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_lock_sha256
          | _ -> `Null) )
     ; ( "build_environment_profile_sha256"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_environment_profile_sha256
          | _ -> `Null) )
     ; ( "build_environment_path_identity_sha256"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_environment_path_identity_sha256
          | _ -> `Null) )
     ; ( "build_environment_path_executable_sha256"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_environment_path_executable_sha256
          | _ -> `Null) )
     ; ( "build_environment_path_executable_count"
       , (match manifest_identity with
          | Some manifest -> `Int manifest.build_environment_path_executable_count
          | _ -> `Null) )
     ; ( "build_producer"
       , (match manifest_identity with
          | Some manifest -> `String manifest.build_producer
          | _ -> `Null) )
     ; ( "build_runtime"
       , (match manifest_identity with
          | Some manifest ->
            `Assoc
              [ "node", `String manifest.build_node_version
              ; "node_platform", `String manifest.build_node_platform
              ; "node_arch", `String manifest.build_node_arch
              ; "package_manager_kind", `String manifest.build_package_manager_kind
              ; "pnpm", `String manifest.build_pnpm_version
              ; "vite", `String manifest.build_vite_version
              ; "installed_graph_metadata_sha256", `String manifest.build_installed_graph_metadata_sha256
              ; "installed_graph_metadata_count", `Int manifest.build_installed_graph_metadata_count
              ; "mode", `String manifest.build_mode
              ]
          | _ -> `Null) )
     ; ("recovery", surface_recovery_json recovery)
     ]
     @ freshness_fields)

let html () =
  match load_dashboard_asset "index.html" with
  | Ok body -> body
  | Error _ ->
    "<html><body>Dashboard assets unavailable. Inspect /health dashboard_surface.recovery.</body></html>"

let etag () =
  match load_dashboard_asset "index.html" with
  | Ok body ->
    let hash = Digest.string body |> Digest.to_hex in
    String.sub hash 0 12
  | Error _ -> "none"

let is_safe_asset_relative_path rel =
  String.length rel > 0
  && Filename.is_relative rel
  && not (String.contains rel '\\')
  && not (String.contains rel '\000')
  &&
  let segments = String.split_on_char '/' rel in
  List.for_all
    (fun seg ->
      String.length seg > 0
      && seg <> "."
      && seg <> "..")
    segments

module For_testing = struct
  let surface_recovery = surface_recovery
  let surface_recovery_json = surface_recovery_json
  let select_assets_root = select_assets_root
  let load_and_verify_dashboard_blob = load_and_verify_dashboard_blob
end
