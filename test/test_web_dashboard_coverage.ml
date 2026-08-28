(** Web_dashboard Module Coverage Tests

    Tests for MASC Web Dashboard (Preact + HTM SPA):
    - html: reads Vite-built index.html from assets/dashboard/
    - etag: mtime-based content hash for caching
    - fallback: returns error page when build not found
*)

open Alcotest

module Web_dashboard = Masc.Web_dashboard
module Build_identity = Masc.Build_identity

(* Under `dune test`, the working directory differs from the project root,
   so assets_root() can't find assets/dashboard/index.html.
   Resolve it from the executable path: _build/default/test/foo.exe → 3 dirs up. *)
let has_repo_root root =
  Sys.file_exists (Filename.concat root "dune-project")
  && Sys.file_exists (Filename.concat (Filename.concat root "dashboard") "package.json")
  && Sys.file_exists (Filename.concat (Filename.concat root "lib") "web_dashboard.ml")

let rec ascend_repo_root dir =
  if has_repo_root dir then Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else ascend_repo_root parent

let executable_repo_root () =
  let d = Filename.dirname Sys.executable_name in
  let d = Filename.dirname d in
  let d = Filename.dirname d in
  ascend_repo_root (Filename.dirname d)

let project_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_repo_root root -> root
  | _ ->
      (match ascend_repo_root (Sys.getcwd ()) with
       | Some root -> root
       | None ->
           (match executable_repo_root () with
            | Some root -> root
            | None -> Sys.getcwd ()))

let () =
  if Sys.getenv_opt "MASC_ASSETS_DIR" = None then
    let assets = Filename.concat (project_root ()) "assets" in
    if Sys.file_exists assets then Unix.putenv "MASC_ASSETS_DIR" assets

let contains_re re s =
  try
    let _ = Str.search_forward (Str.regexp re) s 0 in
    true
  with Not_found -> false

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let with_env vars f =
  let original = List.map (fun (name, _) -> (name, Sys.getenv_opt name)) vars in
  List.iter (fun (name, value) -> Unix.putenv name value) vars;
  Fun.protect f ~finally:(fun () ->
    List.iter (fun (name, value) -> restore_env name value) original)

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let read_file path = In_channel.with_open_bin path In_channel.input_all

let make_temp_dashboard_root label marker =
  let root = Filename.temp_file ("masc-dashboard-" ^ label) "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  let assets = Filename.concat root "assets" in
  Unix.mkdir assets 0o755;
  let dashboard = Filename.concat assets "dashboard" in
  Unix.mkdir dashboard 0o755;
  write_file (Filename.concat dashboard "index.html")
    (Printf.sprintf "<!DOCTYPE html><html><body>%s</body></html>" marker);
  root

let cleanup_temp_dashboard_root root =
  let assets = Filename.concat root "assets" in
  let dashboard = Filename.concat assets "dashboard" in
  let index = Filename.concat dashboard "index.html" in
  if Sys.file_exists index then Sys.remove index;
  if Sys.file_exists dashboard then Unix.rmdir dashboard;
  if Sys.file_exists assets then Unix.rmdir assets;
  if Sys.file_exists root then Unix.rmdir root

let make_temp_dir label =
  let root = Filename.temp_file ("masc-dashboard-" ^ label) "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  root

(* ============================================================
   html Tests — Vite SPA index.html
   When assets/dashboard/ is not built (e.g. CI without pnpm run build),
   Web_dashboard.html() returns a fallback page.  Tests adapt accordingly.
   ============================================================ *)

let dashboard_built () =
  let root = project_root () in
  let index = Filename.concat (Filename.concat root "assets") "dashboard/index.html" in
  Sys.file_exists index

let test_html_nonempty () =
  let html = Web_dashboard.html () in
  check bool "nonempty" true (String.length html > 0)

let test_html_starts_with_doctype () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "doctype" true
      (String.length html >= 15 && String.sub html 0 15 = "<!DOCTYPE html>")
  else
    check bool "fallback contains error" true
      (String_util.contains_substring html "Dashboard assets unavailable")

let test_html_contains_head () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has head" true (String_util.contains_substring html "<head>")
  else
    check bool "fallback is non-empty" true (String.length html > 0)

let test_html_contains_body () =
  let html = Web_dashboard.html () in
  check bool "has body" true (String_util.contains_substring html "<body>")

let test_html_contains_title () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has MASC title" true (String_util.contains_substring html "MASC Dashboard")
  else
    check bool "fallback mentions dashboard" true
      (String_util.contains_substring html "Dashboard")

let test_html_contains_stylesheet () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has stylesheet link" true
      (contains_re "rel=\"stylesheet\"" html
       || String_util.contains_substring html "<style>")
  else
    check bool "fallback has no stylesheet" true
      (not (contains_re "rel=\"stylesheet\"" html)
       && not (String_util.contains_substring html "<style>"))

let test_html_contains_script () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has script" true (contains_re "<script" html)
  else
    check bool "fallback has no script" true
      (not (contains_re "<script" html))

let test_html_contains_app_mount () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has app mount div" true (String_util.contains_substring html "id=\"app\"")
  else
    check bool "fallback has no app mount" true
      (not (String_util.contains_substring html "id=\"app\""))

let test_html_ends_with_html_tag () =
  let html = Web_dashboard.html () in
  let trimmed = String.trim html in
  let len = String.length trimmed in
  check bool "ends with </html>" true
    (len >= 7 && String.sub trimmed (len - 7) 7 = "</html>")

let test_html_references_dashboard_assets () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "references dashboard assets" true
      (String_util.contains_substring html "/dashboard/assets/")
  else
    check bool "fallback does not reference assets" false
      (String_util.contains_substring html "/dashboard/assets/")


(* ============================================================
   etag Tests
   ============================================================ *)

let test_etag_nonempty () =
  let etag = Web_dashboard.etag () in
  check bool "etag nonempty" true (String.length etag > 0)

let test_etag_length () =
  let etag = Web_dashboard.etag () in
  (* etag is a 12-char hex hash or "none" *)
  check bool "etag is 12 chars or 'none'" true
    (String.length etag = 12 || etag = "none")

let test_etag_stable () =
  let e1 = Web_dashboard.etag () in
  let e2 = Web_dashboard.etag () in
  check string "etag is stable across calls" e1 e2

(* ============================================================
   Fallback behavior
   ============================================================ *)

let test_fallback_on_missing_asset () =
  let missing_assets_root = make_temp_dir "missing-assets" in
  Fun.protect
    (fun () ->
      with_env
        [
          ("MASC_ASSETS_DIR", missing_assets_root);
          ("MASC_BASE_PATH", "");
        ]
        (fun () ->
          let html = Web_dashboard.html () in
          let etag = Web_dashboard.etag () in
          check bool "fallback html contains error message" true
            (String_util.contains_substring html "Dashboard assets unavailable");
          check string "fallback etag is none" "none" etag))
    ~finally:(fun () -> Unix.rmdir missing_assets_root)

let test_html_ignores_invalid_explicit_assets_dir () =
  let base_root = make_temp_dashboard_root "base-fallback" "dashboard-from-base-path" in
  Fun.protect
    (fun () ->
      with_env
        [
          ("MASC_ASSETS_DIR", "/tmp/nonexistent_masc_assets_67890");
          ("MASC_BASE_PATH", base_root);
        ]
        (fun () ->
          let html = Web_dashboard.html () in
          check bool "does not fall back to base_path assets" false
            (String_util.contains_substring html "dashboard-from-base-path")))
    ~finally:(fun () -> cleanup_temp_dashboard_root base_root)

let test_html_ignores_base_path_assets () =
  let base_root = make_temp_dashboard_root "base" "dashboard-from-base-path" in
  Fun.protect
    (fun () ->
      with_env
        [
          ("MASC_ASSETS_DIR", "");
          ("MASC_BASE_PATH", base_root);
        ]
        (fun () ->
          let html = Web_dashboard.html () in
          check bool "ignores base_path assets" false
            (String_util.contains_substring html "dashboard-from-base-path")))
    ~finally:(fun () ->
      cleanup_temp_dashboard_root base_root)

let test_bound_worktree_assets_override_valid_common_assets () =
  let common_root = make_temp_dashboard_root "common-authority" "common-dashboard" in
  let worktree_root =
    make_temp_dashboard_root "worktree-authority" "worktree-dashboard"
  in
  Fun.protect
    ~finally:(fun () ->
      cleanup_temp_dashboard_root worktree_root;
      cleanup_temp_dashboard_root common_root)
    (fun () ->
      let selected =
        Web_dashboard.For_testing.select_assets_root
          ~launch_source_root_state:(Build_identity.Bound_valid worktree_root)
          ~configured_assets_dir:(Some (Filename.concat common_root "assets"))
          ~exe_dir:(Filename.concat common_root "_build/default/bin")
          ~cwd:common_root
          ~is_dir:Sys.is_directory
      in
      check (option string) "bound worktree asset root wins"
        (Some (Filename.concat worktree_root "assets")) selected;
      let selected = Option.get selected in
      check string "selected index is the worktree build"
        "<!DOCTYPE html><html><body>worktree-dashboard</body></html>"
        (read_file (Filename.concat selected "dashboard/index.html")))

let test_invalid_binding_never_falls_back_but_unbound_launch_can () =
  let configured = "/configured/assets" in
  let select state =
    Web_dashboard.For_testing.select_assets_root
      ~launch_source_root_state:state
      ~configured_assets_dir:(Some configured)
      ~exe_dir:"/repo/_build/default/bin"
      ~cwd:"/cwd"
      ~is_dir:(fun path -> String.equal path configured)
  in
  check (option string) "unbound uses configured root" (Some configured)
    (select Build_identity.Unbound);
  check (option string) "invalid bound identity fails closed" None
    (select (Build_identity.Bound_invalid Build_identity.Source_root_inode_differs))
;;

let test_verified_blob_returns_manifest_bytes_and_rejects_replacement () =
  let snapshot_root = make_temp_dir "verified-blob" |> Unix.realpath in
  Unix.chmod snapshot_root 0o700;
  let path = Filename.concat snapshot_root (String.make 64 'a') in
  let original = "verified dashboard chunk" in
  write_file path original;
  Unix.chmod path 0o600;
  let snapshot_stat = Unix.stat snapshot_root in
  let expected_sha256 = Digestif.SHA256.(digest_string original |> to_hex) in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path;
      if Sys.file_exists snapshot_root then Unix.rmdir snapshot_root)
    (fun () ->
      (match
         Web_dashboard.For_testing.load_and_verify_dashboard_blob
           ~snapshot_root
           ~expected_snapshot_device:snapshot_stat.st_dev
           ~expected_snapshot_inode:snapshot_stat.st_ino
           ~launch_source_root:snapshot_root
           ~expected_source_device:snapshot_stat.st_dev
           ~expected_source_inode:snapshot_stat.st_ino
           path
           ~expected_size:(String.length original)
           ~expected_sha256
       with
       | Ok body -> Alcotest.(check string) "exact manifest bytes" original body
       | Error _ -> Alcotest.fail "verified manifest bytes were rejected");
      write_file path (String.make (String.length original) 'x');
      Unix.chmod path 0o600;
      Alcotest.(check bool)
        "same-size replacement rejected"
        true
        (Result.is_error
           (Web_dashboard.For_testing.load_and_verify_dashboard_blob
              ~snapshot_root
              ~expected_snapshot_device:snapshot_stat.st_dev
              ~expected_snapshot_inode:snapshot_stat.st_ino
              ~launch_source_root:snapshot_root
              ~expected_source_device:snapshot_stat.st_dev
              ~expected_source_inode:snapshot_stat.st_ino
              path
              ~expected_size:(String.length original)
              ~expected_sha256));
      Sys.remove path;
      (match
         Web_dashboard.For_testing.load_and_verify_dashboard_blob
           ~snapshot_root
           ~expected_snapshot_device:snapshot_stat.st_dev
           ~expected_snapshot_inode:snapshot_stat.st_ino
           ~launch_source_root:snapshot_root
           ~expected_source_device:snapshot_stat.st_dev
           ~expected_source_inode:snapshot_stat.st_ino
           path
           ~expected_size:(String.length original)
           ~expected_sha256
       with
       | Error error ->
         Alcotest.(check string)
           "missing manifested blob is 503"
           "503"
           (match Web_dashboard.asset_error_http_status error with
            | `Service_unavailable -> "503"
            | `Not_found -> "404")
       | Ok _ -> Alcotest.fail "missing manifested blob was served"))
;;

let test_verified_blob_rejects_same_path_root_replacement () =
  let snapshot_root = make_temp_dir "replaced-blob-root" in
  Unix.chmod snapshot_root 0o700;
  let displaced_root = snapshot_root ^ ".displaced" in
  let blob_name = String.make 64 'b' in
  let original = "same bytes" in
  let write_blob root =
    let path = Filename.concat root blob_name in
    write_file path original;
    Unix.chmod path 0o600;
    path
  in
  let original_path = write_blob snapshot_root in
  let snapshot_stat = Unix.stat snapshot_root in
  let expected_sha256 = Digestif.SHA256.(digest_string original |> to_hex) in
  Fun.protect
    ~finally:(fun () ->
      let remove_root root =
        let path = Filename.concat root blob_name in
        if Sys.file_exists path then Sys.remove path;
        if Sys.file_exists root then Unix.rmdir root
      in
      remove_root snapshot_root;
      remove_root displaced_root)
    (fun () ->
      Unix.rename snapshot_root displaced_root;
      Unix.mkdir snapshot_root 0o700;
      ignore (write_blob snapshot_root);
      Alcotest.(check bool)
        "same-path replacement root rejected"
        true
        (Result.is_error
           (Web_dashboard.For_testing.load_and_verify_dashboard_blob
              ~snapshot_root:(Unix.realpath snapshot_root)
              ~expected_snapshot_device:snapshot_stat.st_dev
              ~expected_snapshot_inode:snapshot_stat.st_ino
              ~launch_source_root:(Unix.realpath snapshot_root)
              ~expected_source_device:snapshot_stat.st_dev
              ~expected_source_inode:snapshot_stat.st_ino
              (Filename.concat (Unix.realpath snapshot_root) blob_name)
              ~expected_size:(String.length original)
              ~expected_sha256));
      ignore original_path)
;;

let test_verified_blob_rejects_launch_source_replacement () =
  let source_root = make_temp_dir "replaced-source" |> Unix.realpath in
  let displaced_source = source_root ^ ".displaced" in
  let snapshot_root = make_temp_dir "stable-blob-root" |> Unix.realpath in
  Unix.chmod snapshot_root 0o700;
  let source_stat = Unix.stat source_root in
  let snapshot_stat = Unix.stat snapshot_root in
  let body = "stable bytes" in
  let path = Filename.concat snapshot_root (String.make 64 'c') in
  write_file path body;
  Unix.chmod path 0o600;
  let digest = Digestif.SHA256.(digest_string body |> to_hex) in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path;
      if Sys.file_exists snapshot_root then Unix.rmdir snapshot_root;
      if Sys.file_exists source_root then Unix.rmdir source_root;
      if Sys.file_exists displaced_source then Unix.rmdir displaced_source)
    (fun () ->
      Alcotest.(check bool)
        "launch source replacement after exact read rejected"
        true
        (Result.is_error
           (Web_dashboard.For_testing.load_and_verify_dashboard_blob
              ~after_exact_read:(fun () ->
                Unix.rename source_root displaced_source;
                Unix.mkdir source_root 0o755)
              ~snapshot_root
              ~expected_snapshot_device:snapshot_stat.st_dev
              ~expected_snapshot_inode:snapshot_stat.st_ino
              ~launch_source_root:source_root
              ~expected_source_device:source_stat.st_dev
              ~expected_source_inode:source_stat.st_ino
              path
              ~expected_size:(String.length body)
              ~expected_sha256:digest)))
;;

let test_asset_error_http_status_preserves_identity_failures () =
  let status_name = function
    | `Not_found -> "404"
    | `Service_unavailable -> "503"
  in
  let check_status label expected error =
    Alcotest.(check string)
      label
      (status_name expected)
      (status_name (Web_dashboard.asset_error_http_status error))
  in
  check_status "unmanifested is 404" `Not_found Web_dashboard.Asset_not_manifested;
  check_status
    "missing receipt is 503"
    `Service_unavailable
    Web_dashboard.Asset_build_unavailable;
  check_status
    "digest failure is 503"
    `Service_unavailable
    (Web_dashboard.Asset_exact_read_failed "digest")
;;

(* ============================================================
   Asset path safety
   ============================================================ *)

let test_safe_asset_relative_path_accepts_normal () =
  check bool "normal asset path allowed" true
    (Web_dashboard.is_safe_asset_relative_path "index-Dt8oKM_U.js")

let test_safe_asset_relative_path_rejects_parent_traversal () =
  check bool "parent traversal rejected" false
    (Web_dashboard.is_safe_asset_relative_path "../secrets.txt")

let test_safe_asset_relative_path_rejects_nested_parent_traversal () =
  check bool "nested parent traversal rejected" false
    (Web_dashboard.is_safe_asset_relative_path "js/../../etc/passwd")

let test_safe_asset_relative_path_rejects_empty_segment () =
  check bool "double slash rejected" false
    (Web_dashboard.is_safe_asset_relative_path "js//bundle.js")

let test_safe_asset_relative_path_rejects_absolute () =
  check bool "absolute path rejected" false
    (Web_dashboard.is_safe_asset_relative_path "/etc/passwd")

(* ============================================================
   bundle_freshness Tests — .build-stamp vs. running binary mtime
   ============================================================ *)

(* Guaranteed older than any real build, and deliberately not 0.0: passing
   0.0 for both atime and mtime to Unix.utimes means "set to the current
   time" (POSIX utimes(path, NULL) semantics), not "set to the Unix epoch" —
   an easy Stdlib-API trap that would have made this fixture a no-op. *)
let long_ago = 1.0

let with_temp_dashboard_root ?stamp_mtime f =
  let root = make_temp_dashboard_root "freshness" "freshness-marker" in
  Fun.protect
    (fun () ->
      (match stamp_mtime with
       | None -> ()
       | Some mtime ->
         let stamp =
           Filename.concat (Filename.concat (Filename.concat root "assets") "dashboard")
             ".build-stamp"
         in
         write_file stamp "";
         Unix.utimes stamp mtime mtime);
      with_env [ ("MASC_ASSETS_DIR", Filename.concat root "assets"); ("MASC_BASE_PATH", "") ] f)
    ~finally:(fun () ->
      let stamp =
        Filename.concat (Filename.concat (Filename.concat root "assets") "dashboard")
          ".build-stamp"
      in
      if Sys.file_exists stamp then Sys.remove stamp;
      cleanup_temp_dashboard_root root)

let test_bundle_freshness_missing_stamp () =
  with_temp_dashboard_root (fun () ->
    check bool "missing stamp reported, not silently fresh" true
      (match Web_dashboard.bundle_freshness () with
       | Missing_stamp -> true
       | Fresh | Stale _ -> false))

let test_bundle_freshness_stale_when_stamp_predates_binary () =
  with_temp_dashboard_root ~stamp_mtime:long_ago (fun () ->
    check bool "stamp older than the running binary is reported stale" true
      (match Web_dashboard.bundle_freshness () with
       | Stale _ -> true
       | Fresh | Missing_stamp -> false))

let test_bundle_freshness_fresh_when_stamp_after_binary () =
  (* A stamp far in the future is always newer than the test binary's real
     build mtime — exercises the Fresh branch without needing to touch the
     binary itself. *)
  let far_future = Unix.gettimeofday () +. (365.0 *. 24.0 *. 3600.0) in
  with_temp_dashboard_root ~stamp_mtime:far_future (fun () ->
    check bool "stamp newer than the running binary is fresh" true
      (match Web_dashboard.bundle_freshness () with
       | Fresh -> true
       | Stale _ | Missing_stamp -> false))

let test_bundle_freshness_build_stamp_path_under_dashboard_assets () =
  with_temp_dashboard_root (fun () ->
    check bool "build_stamp_path lives under assets/dashboard/" true
      (String_util.contains_substring
         (Option.get (Web_dashboard.build_stamp_path ()))
         "/dashboard/.build-stamp"))

(* log_bundle_freshness_warning has no return value to assert on (there is no
   existing Log capture harness in this suite) — these are smoke tests
   confirming it does not raise in any of the three bundle_freshness states,
   covering the Missing_stamp / Stale / Fresh match arms. *)
let test_log_bundle_freshness_warning_does_not_raise_on_missing_stamp () =
  with_temp_dashboard_root (fun () -> Web_dashboard.log_bundle_freshness_warning ())

let test_log_bundle_freshness_warning_does_not_raise_on_stale () =
  with_temp_dashboard_root ~stamp_mtime:long_ago (fun () ->
    Web_dashboard.log_bundle_freshness_warning ())

let test_log_bundle_freshness_warning_does_not_raise_on_fresh () =
  let far_future = Unix.gettimeofday () +. (365.0 *. 24.0 *. 3600.0) in
  with_temp_dashboard_root ~stamp_mtime:far_future (fun () ->
    Web_dashboard.log_bundle_freshness_warning ())

(* ============================================================
   surface_status_json: /health projection of the dashboard surface
   ============================================================ *)

let assoc_field name = function
  | `Assoc kvs -> List.assoc_opt name kvs
  | _ -> None

let status_of json =
  match assoc_field "status" json with
  | Some (`String s) -> s
  | _ -> "<no-status>"

let index_present_of json =
  match assoc_field "index_present" json with
  | Some (`Bool b) -> b
  | _ -> fail "index_present field missing"

let recovery_field name json =
  match assoc_field "recovery" json with
  | Some (`Assoc recovery) -> List.assoc_opt name recovery
  | _ -> None

let recovery_kind_of json =
  match recovery_field "kind" json with
  | Some (`String kind) -> kind
  | _ -> "<no-recovery-kind>"

let recovery_reason_of json =
  match recovery_field "reason" json with
  | Some (`String reason) -> reason
  | _ -> "<no-recovery-reason>"

let restart_required_of json =
  match recovery_field "restart_required" json with
  | Some (`Bool restart_required) -> restart_required
  | _ -> fail "recovery.restart_required field missing"

let test_surface_status_ok_when_fresh_and_index_present () =
  let far_future = Unix.gettimeofday () +. (365.0 *. 24.0 *. 3600.0) in
  with_temp_dashboard_root ~stamp_mtime:far_future (fun () ->
    let json = Web_dashboard.surface_status_json () in
    check string "status" "ok" (status_of json);
    check bool "index_present" true (index_present_of json);
    check string "recovery kind" "none" (recovery_kind_of json);
    check bool "restart not required" false (restart_required_of json);
    check bool "build_stamp_at present" true
      (assoc_field "build_stamp_at" json <> None);
    check string "index identity is SHA-256" "64"
      (match assoc_field "index_sha256" json with
       | Some (`String digest) -> string_of_int (String.length digest)
       | _ -> "missing");
    check string "build stamp path is inspectable"
      (Option.get (Web_dashboard.build_stamp_path ()))
      (match assoc_field "build_stamp_path" json with
       | Some (`String path) -> path
       | _ -> "missing");
    List.iter
      (fun field ->
        check bool (field ^ " is projected") true (assoc_field field json <> None))
      [ "asset_tree_sha256"
      ; "asset_file_count"
      ; "dashboard_manifest_root"
      ; "build_input_sha256"
      ; "build_head_tree"
      ; "build_index_tree"
      ; "build_environment_path_identity_sha256"
      ; "build_environment_path_executable_sha256"
      ; "build_environment_path_executable_count"
      ; "build_environment_profile_sha256"
      ; "build_runtime"
      ])

let test_surface_status_stale_when_stamp_predates_binary () =
  with_temp_dashboard_root ~stamp_mtime:long_ago (fun () ->
    let json = Web_dashboard.surface_status_json () in
    check string "status" "stale" (status_of json);
    check bool "binary_built_at present" true
      (assoc_field "binary_built_at" json <> None);
    check string "recovery kind" "build_in_place" (recovery_kind_of json);
    check string "recovery reason" "unbound_assets_stale" (recovery_reason_of json);
    check bool "restart not required" false (restart_required_of json))

let test_surface_status_missing_without_stamp () =
  with_temp_dashboard_root (fun () ->
    let json = Web_dashboard.surface_status_json () in
    check string "status" "missing" (status_of json);
    check bool "index_present stays true" true (index_present_of json);
    check string "recovery kind" "build_in_place" (recovery_kind_of json);
    check string "recovery reason" "unbound_assets_missing" (recovery_reason_of json);
    check bool "restart not required" false (restart_required_of json))

let test_surface_status_missing_when_index_absent_despite_fresh_stamp () =
  let far_future = Unix.gettimeofday () +. (365.0 *. 24.0 *. 3600.0) in
  with_temp_dashboard_root ~stamp_mtime:far_future (fun () ->
    (* Partially-deployed tree: the stamp survived, index.html did not. *)
    let index =
      Filename.concat
        (Filename.concat (Option.get (Web_dashboard.assets_root ())) "dashboard")
        "index.html"
    in
    if Sys.file_exists index then Sys.remove index;
    let json = Web_dashboard.surface_status_json () in
    check string "status" "missing" (status_of json);
    check bool "index_present" false (index_present_of json);
    check string "recovery kind" "build_in_place" (recovery_kind_of json);
    check bool "restart not required" false (restart_required_of json))

let check_recovery_json ~kind ~reason ~restart_required recovery =
  let json =
    `Assoc
      [ "recovery", Web_dashboard.For_testing.surface_recovery_json recovery ]
  in
  check string "recovery kind" kind (recovery_kind_of json);
  check string "recovery reason" reason (recovery_reason_of json);
  check bool "restart required" restart_required (restart_required_of json)

let test_surface_recovery_exact_states () =
  let unavailable =
    Web_dashboard.For_testing.surface_recovery
      ~asset_resolution:Build_identity.Dashboard_assets_unavailable
      ~loaded_index:(Error Web_dashboard.Asset_build_unavailable)
      ~freshness:Web_dashboard.Missing_stamp
  in
  check_recovery_json
    ~kind:"restart_with_exact_build"
    ~reason:"build_receipt_unavailable"
    ~restart_required:true
    unavailable;
  let invalid =
    Web_dashboard.For_testing.surface_recovery
      ~asset_resolution:
        (Build_identity.Dashboard_assets_invalid
           (Build_identity.Dashboard_source_root_invalid
              Build_identity.Source_root_inode_differs))
      ~loaded_index:
        (Error
           (Web_dashboard.Asset_binding_invalid
              (Build_identity.Dashboard_source_root_invalid
                 Build_identity.Source_root_inode_differs)))
      ~freshness:Web_dashboard.Missing_stamp
  in
  check_recovery_json
    ~kind:"repair_exact_artifacts_and_restart"
    ~reason:"binding_invalid"
    ~restart_required:true
    invalid;
  check_recovery_json
    ~kind:"repair_exact_artifacts_and_restart"
    ~reason:"exact_read_failed"
    ~restart_required:true
    (Web_dashboard.Repair_exact_artifacts_and_restart Web_dashboard.Exact_read_failed)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Web_dashboard Coverage" [
    "html", [
      test_case "nonempty" `Quick test_html_nonempty;
      test_case "doctype" `Quick test_html_starts_with_doctype;
      test_case "head" `Quick test_html_contains_head;
      test_case "body" `Quick test_html_contains_body;
      test_case "title" `Quick test_html_contains_title;
      test_case "stylesheet" `Quick test_html_contains_stylesheet;
      test_case "script" `Quick test_html_contains_script;
      test_case "app mount" `Quick test_html_contains_app_mount;
      test_case "ends with html" `Quick test_html_ends_with_html_tag;
      test_case "dashboard assets" `Quick test_html_references_dashboard_assets;
      test_case "verified blob rejects replacement" `Quick
        test_verified_blob_returns_manifest_bytes_and_rejects_replacement;
      test_case "verified blob rejects root replacement" `Quick
        test_verified_blob_rejects_same_path_root_replacement;
      test_case "verified blob rejects launch source replacement" `Quick
        test_verified_blob_rejects_launch_source_replacement;
      test_case "asset error status preserves failures" `Quick
        test_asset_error_http_status_preserves_identity_failures;
    ];
    "etag", [
      test_case "nonempty" `Quick test_etag_nonempty;
      test_case "length" `Quick test_etag_length;
      test_case "stable" `Quick test_etag_stable;
    ];
    "fallback", [
      test_case "missing asset dir" `Quick test_fallback_on_missing_asset;
      test_case "invalid explicit assets dir ignores base path" `Quick test_html_ignores_invalid_explicit_assets_dir;
      test_case "base_path assets ignored" `Quick test_html_ignores_base_path_assets;
      test_case "bound worktree assets override common assets" `Quick
        test_bound_worktree_assets_override_valid_common_assets;
      test_case "invalid binding does not fall back" `Quick
        test_invalid_binding_never_falls_back_but_unbound_launch_can;
    ];
    "asset_path_safety", [
      test_case "accept normal" `Quick test_safe_asset_relative_path_accepts_normal;
      test_case "reject parent traversal" `Quick test_safe_asset_relative_path_rejects_parent_traversal;
      test_case "reject nested traversal" `Quick test_safe_asset_relative_path_rejects_nested_parent_traversal;
      test_case "reject empty segment" `Quick test_safe_asset_relative_path_rejects_empty_segment;
      test_case "reject absolute path" `Quick test_safe_asset_relative_path_rejects_absolute;
    ];
    "bundle_freshness", [
      test_case "missing stamp" `Quick test_bundle_freshness_missing_stamp;
      test_case "stale when stamp predates binary" `Quick test_bundle_freshness_stale_when_stamp_predates_binary;
      test_case "fresh when stamp postdates binary" `Quick test_bundle_freshness_fresh_when_stamp_after_binary;
      test_case "build_stamp_path under dashboard assets" `Quick test_bundle_freshness_build_stamp_path_under_dashboard_assets;
      test_case "warn does not raise on missing stamp" `Quick test_log_bundle_freshness_warning_does_not_raise_on_missing_stamp;
      test_case "warn does not raise on stale" `Quick test_log_bundle_freshness_warning_does_not_raise_on_stale;
      test_case "warn does not raise on fresh" `Quick test_log_bundle_freshness_warning_does_not_raise_on_fresh;
    ];
    "surface_status", [
      test_case "ok when fresh and index present" `Quick test_surface_status_ok_when_fresh_and_index_present;
      test_case "stale when stamp predates binary" `Quick test_surface_status_stale_when_stamp_predates_binary;
      test_case "missing without stamp" `Quick test_surface_status_missing_without_stamp;
      test_case "missing when index absent despite fresh stamp" `Quick test_surface_status_missing_when_index_absent_despite_fresh_stamp;
      test_case "exact recovery actions require restart" `Quick test_surface_recovery_exact_states;
    ];
  ]
