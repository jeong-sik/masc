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
let () =
  if Sys.getenv_opt "MASC_ASSETS_ROOT" = None then
    let candidates =
      [ Sys.getenv_opt "DUNE_SOURCEROOT"
      ; (let d = Filename.dirname Sys.executable_name in
         let d = Filename.dirname d in
         let d = Filename.dirname d in
         Some (Filename.dirname d))
      ]
    in
    List.iter
      (fun c ->
        match c with
        | Some p ->
            let assets = Filename.concat p "assets" in
            if Sys.file_exists assets && Sys.getenv_opt "MASC_ASSETS_ROOT" = None
            then Unix.putenv "MASC_ASSETS_ROOT" assets
        | None -> ())
      candidates

let contains_substr sub s =
  try
    let _ = Str.search_forward (Str.regexp_string sub) s 0 in
    true
  with Not_found -> false

let contains_re re s =
  try
    let _ = Str.search_forward (Str.regexp re) s 0 in
    true
  with Not_found -> false

let project_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None ->
      let d = Filename.dirname Sys.executable_name in
      let d = Filename.dirname d in
      let d = Filename.dirname d in
      Filename.dirname d


(* ============================================================
   html Tests — Vite SPA index.html
   When assets/dashboard/ is not built (e.g. CI without npm run build),
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
      (contains_substr "Dashboard build not found" html)

let test_html_contains_head () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has head" true (contains_substr "<head>" html)
  else
    check bool "fallback is non-empty" true (String.length html > 0)

let test_html_contains_body () =
  let html = Web_dashboard.html () in
  check bool "has body" true (contains_substr "<body>" html)

let test_html_contains_title () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has MASC title" true (contains_substr "MASC Dashboard" html)
  else
    check bool "fallback mentions dashboard" true
      (contains_substr "Dashboard" html)

let test_html_contains_stylesheet () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has stylesheet link" true
      (contains_re "rel=\"stylesheet\"" html
       || contains_substr "<style>" html)
  else
    check bool "fallback ok" true true

let test_html_contains_script () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has script" true (contains_re "<script" html)
  else
    check bool "fallback ok" true true

let test_html_contains_app_mount () =
  let html = Web_dashboard.html () in
  if dashboard_built () then
    check bool "has app mount div" true (contains_substr "id=\"app\"" html)
  else
    check bool "fallback ok" true true

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
      (contains_substr "/dashboard/assets/" html)
  else
    check bool "fallback does not reference assets" false
      (contains_substr "/dashboard/assets/" html)


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
  (* Override MASC_ASSETS_ROOT to a nonexistent directory *)
  let original = Sys.getenv_opt "MASC_ASSETS_ROOT" in
  Unix.putenv "MASC_ASSETS_ROOT" "/tmp/nonexistent_masc_assets_12345";
  let html = Web_dashboard.html () in
  let etag = Web_dashboard.etag () in
  (* Restore *)
  (match original with
   | Some v -> Unix.putenv "MASC_ASSETS_ROOT" v
   | None ->
       (* Clear the env var by setting it to a value we can ignore,
          since OCaml stdlib has no unsetenv. The next call to assets_root()
          will use this path which doesn't exist, then fall through to cwd. *)
       Unix.putenv "MASC_ASSETS_ROOT" "");
  check bool "fallback html contains error message" true
    (contains_substr "Dashboard build not found" html);
  check string "fallback etag is none" "none" etag

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
    ];
    "etag", [
      test_case "nonempty" `Quick test_etag_nonempty;
      test_case "length" `Quick test_etag_length;
      test_case "stable" `Quick test_etag_stable;
    ];
    "fallback", [
      test_case "missing asset dir" `Quick test_fallback_on_missing_asset;
    ];
    "asset_path_safety", [
      test_case "accept normal" `Quick test_safe_asset_relative_path_accepts_normal;
      test_case "reject parent traversal" `Quick test_safe_asset_relative_path_rejects_parent_traversal;
      test_case "reject nested traversal" `Quick test_safe_asset_relative_path_rejects_nested_parent_traversal;
      test_case "reject empty segment" `Quick test_safe_asset_relative_path_rejects_empty_segment;
      test_case "reject absolute path" `Quick test_safe_asset_relative_path_rejects_absolute;
    ];
  ]
