(** Web_dashboard Module Coverage Tests

    Tests for MASC Web Dashboard (Preact + HTM SPA):
    - html: reads Vite-built index.html from assets/dashboard/
    - etag: mtime-based content hash for caching
    - fallback: returns error page when build not found
*)

open Alcotest
module Web_dashboard = Masc_mcp.Web_dashboard

(* Under `dune test`, the working directory differs from the project root,
   so assets_root() can't find assets/dashboard/index.html.
   Resolve it from the executable path: _build/default/test/foo.exe → 3 dirs up. *)
let has_repo_root root =
  Sys.file_exists (Filename.concat root "dune-project")
  && Sys.file_exists (Filename.concat (Filename.concat root "dashboard") "package.json")
  && Sys.file_exists (Filename.concat (Filename.concat root "lib") "web_dashboard.ml")
;;

let rec ascend_repo_root dir =
  if has_repo_root dir
  then Some dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else ascend_repo_root parent)
;;

let executable_repo_root () =
  let d = Filename.dirname Sys.executable_name in
  let d = Filename.dirname d in
  let d = Filename.dirname d in
  ascend_repo_root (Filename.dirname d)
;;

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
;;

let () =
  if Sys.getenv_opt "MASC_ASSETS_DIR" = None
  then (
    let assets = Filename.concat (project_root ()) "assets" in
    if Sys.file_exists assets then Unix.putenv "MASC_ASSETS_DIR" assets)
;;

let contains_substr sub s =
  try
    let _ = Str.search_forward (Str.regexp_string sub) s 0 in
    true
  with
  | Not_found -> false
;;

let contains_re re s =
  try
    let _ = Str.search_forward (Str.regexp re) s 0 in
    true
  with
  | Not_found -> false
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let with_env vars f =
  let original = List.map (fun (name, _) -> name, Sys.getenv_opt name) vars in
  List.iter (fun (name, value) -> Unix.putenv name value) vars;
  Fun.protect f ~finally:(fun () ->
    List.iter (fun (name, value) -> restore_env name value) original)
;;

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc
;;

let make_temp_dashboard_root label marker =
  let root = Filename.temp_file ("masc-dashboard-" ^ label) "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  let assets = Filename.concat root "assets" in
  Unix.mkdir assets 0o755;
  let dashboard = Filename.concat assets "dashboard" in
  Unix.mkdir dashboard 0o755;
  write_file
    (Filename.concat dashboard "index.html")
    (Printf.sprintf "<!DOCTYPE html><html><body>%s</body></html>" marker);
  root
;;

let cleanup_temp_dashboard_root root =
  let assets = Filename.concat root "assets" in
  let dashboard = Filename.concat assets "dashboard" in
  let index = Filename.concat dashboard "index.html" in
  if Sys.file_exists index then Sys.remove index;
  if Sys.file_exists dashboard then Unix.rmdir dashboard;
  if Sys.file_exists assets then Unix.rmdir assets;
  if Sys.file_exists root then Unix.rmdir root
;;

let make_temp_dir label =
  let root = Filename.temp_file ("masc-dashboard-" ^ label) "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  root
;;

(* ============================================================
   html Tests — Vite SPA index.html
   When assets/dashboard/ is not built (e.g. CI without pnpm run build),
   Web_dashboard.html() returns a fallback page.  Tests adapt accordingly.
   ============================================================ *)

let dashboard_built () =
  let root = project_root () in
  let index = Filename.concat (Filename.concat root "assets") "dashboard/index.html" in
  Sys.file_exists index
;;

let test_html_nonempty () =
  let html = Web_dashboard.html () in
  check bool "nonempty" true (String.length html > 0)
;;

let test_html_starts_with_doctype () =
  let html = Web_dashboard.html () in
  if dashboard_built ()
  then
    check
      bool
      "doctype"
      true
      (String.length html >= 15 && String.sub html 0 15 = "<!DOCTYPE html>")
  else
    check
      bool
      "fallback contains error"
      true
      (contains_substr "Dashboard build not found" html)
;;

let test_html_contains_head () =
  let html = Web_dashboard.html () in
  if dashboard_built ()
  then check bool "has head" true (contains_substr "<head>" html)
  else check bool "fallback is non-empty" true (String.length html > 0)
;;

let test_html_contains_body () =
  let html = Web_dashboard.html () in
  check bool "has body" true (contains_substr "<body>" html)
;;

let test_html_contains_title () =
  let html = Web_dashboard.html () in
  if dashboard_built ()
  then check bool "has MASC title" true (contains_substr "MASC Dashboard" html)
  else check bool "fallback mentions dashboard" true (contains_substr "Dashboard" html)
;;

let test_html_contains_stylesheet () =
  let html = Web_dashboard.html () in
  if dashboard_built ()
  then
    check
      bool
      "has stylesheet link"
      true
      (contains_re "rel=\"stylesheet\"" html || contains_substr "<style>" html)
  else
    check
      bool
      "fallback has no stylesheet"
      true
      ((not (contains_re "rel=\"stylesheet\"" html))
       && not (contains_substr "<style>" html))
;;

let test_html_contains_script () =
  let html = Web_dashboard.html () in
  if dashboard_built ()
  then check bool "has script" true (contains_re "<script" html)
  else check bool "fallback has no script" true (not (contains_re "<script" html))
;;

let test_html_contains_app_mount () =
  let html = Web_dashboard.html () in
  if dashboard_built ()
  then check bool "has app mount div" true (contains_substr "id=\"app\"" html)
  else
    check bool "fallback has no app mount" true (not (contains_substr "id=\"app\"" html))
;;

let test_html_ends_with_html_tag () =
  let html = Web_dashboard.html () in
  let trimmed = String.trim html in
  let len = String.length trimmed in
  check
    bool
    "ends with </html>"
    true
    (len >= 7 && String.sub trimmed (len - 7) 7 = "</html>")
;;

let test_html_references_dashboard_assets () =
  let html = Web_dashboard.html () in
  if dashboard_built ()
  then
    check
      bool
      "references dashboard assets"
      true
      (contains_substr "/dashboard/assets/" html)
  else
    check
      bool
      "fallback does not reference assets"
      false
      (contains_substr "/dashboard/assets/" html)
;;

(* ============================================================
   etag Tests
   ============================================================ *)

let test_etag_nonempty () =
  let etag = Web_dashboard.etag () in
  check bool "etag nonempty" true (String.length etag > 0)
;;

let test_etag_length () =
  let etag = Web_dashboard.etag () in
  (* etag is a 12-char hex hash or "none" *)
  check bool "etag is 12 chars or 'none'" true (String.length etag = 12 || etag = "none")
;;

let test_etag_stable () =
  let e1 = Web_dashboard.etag () in
  let e2 = Web_dashboard.etag () in
  check string "etag is stable across calls" e1 e2
;;

(* ============================================================
   Fallback behavior
   ============================================================ *)

let test_fallback_on_missing_asset () =
  let missing_assets_root = make_temp_dir "missing-assets" in
  Fun.protect
    (fun () ->
       with_env
         [ "MASC_ASSETS_DIR", missing_assets_root; "MASC_BASE_PATH", "" ]
         (fun () ->
            let html = Web_dashboard.html () in
            let etag = Web_dashboard.etag () in
            check
              bool
              "fallback html contains error message"
              true
              (contains_substr "Dashboard build not found" html);
            check string "fallback etag is none" "none" etag))
    ~finally:(fun () -> Unix.rmdir missing_assets_root)
;;

let test_html_ignores_invalid_explicit_assets_dir () =
  let base_root = make_temp_dashboard_root "base-fallback" "dashboard-from-base-path" in
  Fun.protect
    (fun () ->
       with_env
         [ "MASC_ASSETS_DIR", "/tmp/nonexistent_masc_assets_67890"
         ; "MASC_BASE_PATH", base_root
         ]
         (fun () ->
            let html = Web_dashboard.html () in
            check
              bool
              "does not fall back to base_path assets"
              false
              (contains_substr "dashboard-from-base-path" html)))
    ~finally:(fun () -> cleanup_temp_dashboard_root base_root)
;;

let test_html_ignores_base_path_assets () =
  let base_root = make_temp_dashboard_root "base" "dashboard-from-base-path" in
  Fun.protect
    (fun () ->
       with_env
         [ "MASC_ASSETS_DIR", ""; "MASC_BASE_PATH", base_root ]
         (fun () ->
            let html = Web_dashboard.html () in
            check
              bool
              "ignores base_path assets"
              false
              (contains_substr "dashboard-from-base-path" html)))
    ~finally:(fun () -> cleanup_temp_dashboard_root base_root)
;;

(* ============================================================
   Asset path safety
   ============================================================ *)

let test_safe_asset_relative_path_accepts_normal () =
  check
    bool
    "normal asset path allowed"
    true
    (Web_dashboard.is_safe_asset_relative_path "index-Dt8oKM_U.js")
;;

let test_safe_asset_relative_path_rejects_parent_traversal () =
  check
    bool
    "parent traversal rejected"
    false
    (Web_dashboard.is_safe_asset_relative_path "../secrets.txt")
;;

let test_safe_asset_relative_path_rejects_nested_parent_traversal () =
  check
    bool
    "nested parent traversal rejected"
    false
    (Web_dashboard.is_safe_asset_relative_path "js/../../etc/passwd")
;;

let test_safe_asset_relative_path_rejects_empty_segment () =
  check
    bool
    "double slash rejected"
    false
    (Web_dashboard.is_safe_asset_relative_path "js//bundle.js")
;;

let test_safe_asset_relative_path_rejects_absolute () =
  check
    bool
    "absolute path rejected"
    false
    (Web_dashboard.is_safe_asset_relative_path "/etc/passwd")
;;

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run
    "Web_dashboard Coverage"
    [ ( "html"
      , [ test_case "nonempty" `Quick test_html_nonempty
        ; test_case "doctype" `Quick test_html_starts_with_doctype
        ; test_case "head" `Quick test_html_contains_head
        ; test_case "body" `Quick test_html_contains_body
        ; test_case "title" `Quick test_html_contains_title
        ; test_case "stylesheet" `Quick test_html_contains_stylesheet
        ; test_case "script" `Quick test_html_contains_script
        ; test_case "app mount" `Quick test_html_contains_app_mount
        ; test_case "ends with html" `Quick test_html_ends_with_html_tag
        ; test_case "dashboard assets" `Quick test_html_references_dashboard_assets
        ] )
    ; ( "etag"
      , [ test_case "nonempty" `Quick test_etag_nonempty
        ; test_case "length" `Quick test_etag_length
        ; test_case "stable" `Quick test_etag_stable
        ] )
    ; ( "fallback"
      , [ test_case "missing asset dir" `Quick test_fallback_on_missing_asset
        ; test_case
            "invalid explicit assets dir ignores base path"
            `Quick
            test_html_ignores_invalid_explicit_assets_dir
        ; test_case "base_path assets ignored" `Quick test_html_ignores_base_path_assets
        ] )
    ; ( "asset_path_safety"
      , [ test_case "accept normal" `Quick test_safe_asset_relative_path_accepts_normal
        ; test_case
            "reject parent traversal"
            `Quick
            test_safe_asset_relative_path_rejects_parent_traversal
        ; test_case
            "reject nested traversal"
            `Quick
            test_safe_asset_relative_path_rejects_nested_parent_traversal
        ; test_case
            "reject empty segment"
            `Quick
            test_safe_asset_relative_path_rejects_empty_segment
        ; test_case
            "reject absolute path"
            `Quick
            test_safe_asset_relative_path_rejects_absolute
        ] )
    ]
;;
