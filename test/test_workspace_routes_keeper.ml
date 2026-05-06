(* Unit tests for the [?keeper=<name>] dispatch in
   [Server_routes_http_routes_workspace.classify_keeper_query].

   The function under test is the pure classification core of
   [resolve_workspace_base]: it takes the project root, two injected
   side-effect closures (lookup + existence check), and the raw query
   parameter, then returns the resolved base directory plus a tag.

   These tests cover all four branches of the classification:
     - [`Project]            — no keeper / empty / whitespace-only
     - [`Playground name]    — keeper meta exists and dir is on disk
     - [`PlaygroundMissing]  — keeper meta exists but dir is missing
     - [`KeeperUnknown]      — no keeper meta for the given name *)

module W = Masc_mcp.Server_routes_http_routes_workspace
module P = Masc_mcp.Prometheus

let project = "/repo"
let repository_root = "/repo/.masc/repos/masc"
let playground_root = "/playgrounds/<keeper>"

let no_lookup _ = None
let always_missing _ = false

let lookup_for known name = if name = known then Some playground_root else None
let lookup_repo_for known name = if name = known then Some repository_root else None
let exists_only path expected = path = expected

let contains needle haystack =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0 then true
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

let test_no_param () =
  let (base, src) =
    W.classify_keeper_query
      ~project_base:project
      ~lookup_playground:no_lookup
      ~exists_dir:always_missing
      None
  in
  Alcotest.(check string) "base is project" project base;
  match src with
  | `Project -> ()
  | _ -> Alcotest.fail "expected `Project for None"

let test_empty_param () =
  let (base, src) =
    W.classify_keeper_query
      ~project_base:project
      ~lookup_playground:no_lookup
      ~exists_dir:always_missing
      (Some "")
  in
  Alcotest.(check string) "base is project" project base;
  match src with
  | `Project -> ()
  | _ -> Alcotest.fail "expected `Project for empty string"

let test_whitespace_param () =
  let (base, src) =
    W.classify_keeper_query
      ~project_base:project
      ~lookup_playground:no_lookup
      ~exists_dir:always_missing
      (Some "   ")
  in
  Alcotest.(check string) "base is project (whitespace trims)" project base;
  match src with
  | `Project -> ()
  | _ -> Alcotest.fail "expected `Project for whitespace"

let test_keeper_unknown () =
  let (base, src) =
    W.classify_keeper_query
      ~project_base:project
      ~lookup_playground:no_lookup
      ~exists_dir:always_missing
      (Some "ghost")
  in
  Alcotest.(check string) "fallback to project" project base;
  match src with
  | `KeeperUnknown name ->
    Alcotest.(check string) "carries trimmed name" "ghost" name
  | _ -> Alcotest.fail "expected `KeeperUnknown"

let test_playground_resolved () =
  let (base, src) =
    W.classify_keeper_query
      ~project_base:project
      ~lookup_playground:(lookup_for "alpha")
      ~exists_dir:(exists_only playground_root)
      (Some "alpha")
  in
  Alcotest.(check string) "base is playground" playground_root base;
  match src with
  | `Playground name ->
    Alcotest.(check string) "carries trimmed name" "alpha" name
  | _ -> Alcotest.fail "expected `Playground"

let test_playground_missing () =
  let (base, src) =
    W.classify_keeper_query
      ~project_base:project
      ~lookup_playground:(lookup_for "alpha")
      ~exists_dir:always_missing  (* meta exists but dir is gone *)
      (Some "alpha")
  in
  Alcotest.(check string) "fallback to project" project base;
  match src with
  | `PlaygroundMissing name ->
    Alcotest.(check string) "carries trimmed name" "alpha" name
  | _ -> Alcotest.fail "expected `PlaygroundMissing"

let test_keeper_name_trimmed () =
  let (base, src) =
    W.classify_keeper_query
      ~project_base:project
      ~lookup_playground:(lookup_for "alpha")
      ~exists_dir:(exists_only playground_root)
      (Some "  alpha  ")
  in
  Alcotest.(check string) "base is playground" playground_root base;
  match src with
  | `Playground name ->
    Alcotest.(check string) "name is trimmed" "alpha" name
  | _ -> Alcotest.fail "expected `Playground after trim"

(* ─── classify_workspace_query ──────────────────────────────────── *)

let test_repository_param_takes_precedence () =
  let (base, src) =
    W.classify_workspace_query
      ~project_base:project
      ~lookup_repository:(lookup_repo_for "masc")
      ~lookup_playground:(lookup_for "alpha")
      ~exists_dir:(exists_only repository_root)
      ~repo_param:(Some "masc")
      ~keeper_param:(Some "alpha")
  in
  Alcotest.(check string) "base is repository" repository_root base;
  match src with
  | `Repository repo_id ->
    Alcotest.(check string) "repo id" "masc" repo_id
  | _ -> Alcotest.fail "expected `Repository"

let test_repository_param_trimmed () =
  let (base, src) =
    W.classify_workspace_query
      ~project_base:project
      ~lookup_repository:(lookup_repo_for "masc")
      ~lookup_playground:no_lookup
      ~exists_dir:(exists_only repository_root)
      ~repo_param:(Some "  masc  ")
      ~keeper_param:None
  in
  Alcotest.(check string) "base is repository" repository_root base;
  match src with
  | `Repository repo_id ->
    Alcotest.(check string) "repo id trimmed" "masc" repo_id
  | _ -> Alcotest.fail "expected `Repository after trim"

let test_repository_missing_falls_back_to_project () =
  let (base, src) =
    W.classify_workspace_query
      ~project_base:project
      ~lookup_repository:(lookup_repo_for "masc")
      ~lookup_playground:no_lookup
      ~exists_dir:always_missing
      ~repo_param:(Some "masc")
      ~keeper_param:None
  in
  Alcotest.(check string) "fallback to project" project base;
  match src with
  | `RepositoryMissing repo_id ->
    Alcotest.(check string) "repo id" "masc" repo_id
  | _ -> Alcotest.fail "expected `RepositoryMissing"

let test_repository_unknown_falls_back_to_project () =
  let (base, src) =
    W.classify_workspace_query
      ~project_base:project
      ~lookup_repository:no_lookup
      ~lookup_playground:no_lookup
      ~exists_dir:always_missing
      ~repo_param:(Some "ghost")
      ~keeper_param:None
  in
  Alcotest.(check string) "fallback to project" project base;
  match src with
  | `RepositoryUnknown repo_id ->
    Alcotest.(check string) "repo id" "ghost" repo_id
  | _ -> Alcotest.fail "expected `RepositoryUnknown"

let test_workspace_blank_repo_param_uses_keeper () =
  let (base, src) =
    W.classify_workspace_query
      ~project_base:project
      ~lookup_repository:(lookup_repo_for "masc")
      ~lookup_playground:(lookup_for "alpha")
      ~exists_dir:(exists_only playground_root)
      ~repo_param:(Some "  ")
      ~keeper_param:(Some "alpha")
  in
  Alcotest.(check string) "base is playground" playground_root base;
  match src with
  | `Playground keeper ->
    Alcotest.(check string) "keeper" "alpha" keeper
  | _ -> Alcotest.fail "expected `Playground"

(* ─── source_header ─────────────────────────────────────────────── *)

let header_value headers =
  match headers with
  | [(k, v)] when k = "X-Workspace-Source" -> v
  | _ -> Alcotest.fail "expected single X-Workspace-Source header"

let test_header_project () =
  let v = header_value (W.source_header `Project) in
  Alcotest.(check string) "project" "project" v

let test_header_repository () =
  let v = header_value (W.source_header (`Repository "masc")) in
  Alcotest.(check string) "repository encoding" "repository:masc" v

let test_header_repository_missing () =
  let v = header_value (W.source_header (`RepositoryMissing "masc")) in
  Alcotest.(check string) "repository missing encoding" "repository_missing:masc" v

let test_header_repository_unknown () =
  let v = header_value (W.source_header (`RepositoryUnknown "ghost")) in
  Alcotest.(check string) "repository unknown encoding" "repository_unknown:ghost" v

let test_header_playground () =
  let v = header_value (W.source_header (`Playground "alpha")) in
  Alcotest.(check string) "playground encoding" "playground:alpha" v

let test_header_playground_missing () =
  let v = header_value (W.source_header (`PlaygroundMissing "alpha")) in
  Alcotest.(check string) "missing encoding" "playground_missing:alpha" v

let test_header_keeper_unknown () =
  let v = header_value (W.source_header (`KeeperUnknown "ghost")) in
  Alcotest.(check string) "unknown encoding" "keeper_unknown:ghost" v

(* ─── rel_under (path math, root-base safety) ───────────────────── *)

let test_rel_under_normal () =
  Alcotest.(check string) "/repo + /repo/src/main.ml -> src/main.ml"
    "src/main.ml" (W.rel_under "/repo" "/repo/src/main.ml")

let test_rel_under_root_base () =
  Alcotest.(check string) "/ + /etc/hosts -> etc/hosts"
    "etc/hosts" (W.rel_under "/" "/etc/hosts")

let test_rel_under_trailing_slash () =
  Alcotest.(check string) "trailing-slash base normalises"
    "src/a.ml" (W.rel_under "/repo/" "/repo/src/a.ml")

let test_rel_under_equal () =
  Alcotest.(check string) "safe = base -> empty"
    "" (W.rel_under "/repo" "/repo")

(* ─── scan_dir (bounded file-tree scan) ──────────────────────────── *)

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let with_temp_dir name f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-workspace-routes-%d-%s" (Unix.getpid ()) name)
  in
  remove_tree dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let touch path =
  let oc = open_out path in
  close_out oc

let test_scan_dir_respects_max_nodes () =
  with_temp_dir "wide-tree" (fun dir ->
    for i = 1 to 80 do
      touch (Filename.concat dir (Printf.sprintf "file-%03d.txt" i))
    done;
    let nodes = W.scan_dir ~base:dir ~depth:0 ~max_depth:1 ~max_nodes:25 [] dir in
    Alcotest.(check int) "node cap" 25 (List.length nodes))

let test_tree_node_limit_default () =
  Alcotest.(check int) "default" 750 (W.tree_node_limit_of_query None)

let test_tree_node_limit_invalid_falls_back () =
  Alcotest.(check int) "invalid" 750 (W.tree_node_limit_of_query (Some "bad"))

let test_tree_node_limit_clamps_low () =
  Alcotest.(check int) "low" 1 (W.tree_node_limit_of_query (Some "0"))

let test_tree_node_limit_clamps_high () =
  Alcotest.(check int) "high" 2000 (W.tree_node_limit_of_query (Some "9000"))

let test_tree_node_limit_accepts_valid () =
  Alcotest.(check int) "valid" 42 (W.tree_node_limit_of_query (Some "42"))

(* Issue #13191 follow-up: numeric overflow on [int_of_string] used to
   fall back to the default (750) instead of clamping to the documented
   maximum (2000), so a client asking for "very large" got fewer nodes
   than asking for 9000. *)
let test_tree_node_limit_overflow_clamps_to_max () =
  Alcotest.(check int) "huge numeric input clamps to max"
    2000
    (W.tree_node_limit_of_query (Some "99999999999999999999"))

let test_tree_node_limit_overflow_with_underscores () =
  Alcotest.(check int) "huge underscore-separated digits clamp to max"
    2000
    (W.tree_node_limit_of_query (Some "99_999_999_999_999_999_999"))

let test_tree_node_limit_negative_overflow_clamps_low () =
  Alcotest.(check int) "huge negative value clamps to 1"
    1
    (W.tree_node_limit_of_query (Some "-99999999999999999999"))

let test_tree_node_limit_non_numeric_still_default () =
  Alcotest.(check int) "non-numeric junk falls back to default"
    750
    (W.tree_node_limit_of_query (Some "9000abc"))

(* Reviewer #13222: malformed underscore forms must classify as junk and
   fall back to the default, not be promoted to overflow.  These mirror
   OCaml's int_of_string rejection: underscores are only valid between
   digits, never leading/trailing/adjacent. *)
let test_tree_node_limit_lone_underscore_is_junk () =
  Alcotest.(check int) "'_' falls back to default"
    750
    (W.tree_node_limit_of_query (Some "_"))

let test_tree_node_limit_trailing_underscore_is_junk () =
  Alcotest.(check int) "'1_' falls back to default"
    750
    (W.tree_node_limit_of_query (Some "1_"))

let test_tree_node_limit_leading_underscore_is_junk () =
  Alcotest.(check int) "'_1' falls back to default"
    750
    (W.tree_node_limit_of_query (Some "_1"))

let test_tree_node_limit_double_underscore_is_junk () =
  Alcotest.(check int) "'1__2' falls back to default"
    750
    (W.tree_node_limit_of_query (Some "1__2"))

let test_tree_node_limit_signed_lone_underscore_is_junk () =
  Alcotest.(check int) "'+_' falls back to default"
    750
    (W.tree_node_limit_of_query (Some "+_"))

let test_workspace_failure_observer_increments_metric () =
  let labels = [("site", "unit_test")] in
  let before =
    P.metric_value_or_zero P.metric_workspace_route_failures ~labels ()
  in
  W.For_testing.observe_workspace_route_failure
    ~site:"unit_test"
    ~path:"/tmp/missing"
    (Failure "synthetic workspace failure");
  let after =
    P.metric_value_or_zero P.metric_workspace_route_failures ~labels ()
  in
  Alcotest.(check (float 0.0001))
    "workspace route failure counted" (before +. 1.0) after

let test_workspace_log_value_sanitizer_bounds_controlled_text () =
  let sanitized =
    W.For_testing.sanitize_log_value ~max_bytes:12
      "alpha\nbeta\radmin\ttrail-with-extra"
  in
  Alcotest.(check bool) "newlines removed" false (contains "\n" sanitized);
  Alcotest.(check bool) "carriage returns removed" false
    (contains "\r" sanitized);
  Alcotest.(check bool) "tabs removed" false (contains "\t" sanitized);
  Alcotest.(check bool) "bounded with suffix" true (contains "..." sanitized)

let test_workspace_failure_observer_reraises_cancelled () =
  let raised = ref false in
  (try
     W.For_testing.observe_workspace_route_failure
       ~site:"unit_test_cancel"
       ~path:"/tmp/missing"
       (Eio.Cancel.Cancelled (Failure "synthetic cancel"))
   with Eio.Cancel.Cancelled _ -> raised := true);
  Alcotest.(check bool) "cancel is re-raised" true !raised

(* ─── valid_git_ref (option-injection guard) ────────────────────── *)

let test_valid_ref_main () =
  Alcotest.(check bool) "main is valid" true (W.valid_git_ref "main")

let test_valid_ref_sha () =
  Alcotest.(check bool) "40-char SHA is valid"
    true (W.valid_git_ref "0123456789abcdef0123456789abcdef01234567")

let test_valid_ref_path_form () =
  Alcotest.(check bool) "origin/main is valid"
    true (W.valid_git_ref "origin/main")

let test_valid_ref_caret () =
  Alcotest.(check bool) "HEAD^ is valid" true (W.valid_git_ref "HEAD^")

let test_valid_ref_plus () =
  Alcotest.(check bool) "feature+v2 (branch with '+') is valid"
    true (W.valid_git_ref "feature+v2")

let test_valid_ref_upstream_brace () =
  Alcotest.(check bool) "@{upstream} revision is valid"
    true (W.valid_git_ref "@{upstream}")

let test_valid_ref_reflog_brace () =
  Alcotest.(check bool) "HEAD@{1} reflog revision is valid"
    true (W.valid_git_ref "HEAD@{1}")

let test_valid_ref_rejects_leading_dash () =
  Alcotest.(check bool) "leading dash refused"
    false (W.valid_git_ref "-L1,9999")

let test_valid_ref_rejects_empty () =
  Alcotest.(check bool) "empty refused" false (W.valid_git_ref "")

let test_valid_ref_rejects_whitespace () =
  Alcotest.(check bool) "embedded space refused"
    false (W.valid_git_ref "main ; rm -rf /")

let test_valid_ref_rejects_semicolon () =
  Alcotest.(check bool) "semicolon refused"
    false (W.valid_git_ref "main;ls")

let test_valid_ref_rejects_newline () =
  Alcotest.(check bool) "newline refused"
    false (W.valid_git_ref "main\nrm")

let test_valid_ref_rejects_oversize () =
  Alcotest.(check bool) "oversize refused"
    false (W.valid_git_ref (String.make 257 'a'))

let () =
  Alcotest.run "workspace_routes_keeper"
    [ ( "classify_keeper_query"
      , [ Alcotest.test_case "no param"          `Quick test_no_param
        ; Alcotest.test_case "empty param"       `Quick test_empty_param
        ; Alcotest.test_case "whitespace param"  `Quick test_whitespace_param
        ; Alcotest.test_case "keeper unknown"    `Quick test_keeper_unknown
        ; Alcotest.test_case "playground exists" `Quick test_playground_resolved
        ; Alcotest.test_case "playground missing" `Quick test_playground_missing
        ; Alcotest.test_case "name trimmed"      `Quick test_keeper_name_trimmed
        ] )
    ; ( "source_header"
      , [ Alcotest.test_case "project"           `Quick test_header_project
        ; Alcotest.test_case "repository"        `Quick test_header_repository
        ; Alcotest.test_case "repository missing" `Quick test_header_repository_missing
        ; Alcotest.test_case "repository unknown" `Quick test_header_repository_unknown
        ; Alcotest.test_case "playground"        `Quick test_header_playground
        ; Alcotest.test_case "playground missing" `Quick test_header_playground_missing
        ; Alcotest.test_case "keeper unknown"    `Quick test_header_keeper_unknown
        ] )
    ; ( "classify_workspace_query"
      , [ Alcotest.test_case "repository takes precedence" `Quick test_repository_param_takes_precedence
        ; Alcotest.test_case "repository param trimmed" `Quick test_repository_param_trimmed
        ; Alcotest.test_case "repository missing" `Quick test_repository_missing_falls_back_to_project
        ; Alcotest.test_case "repository unknown" `Quick test_repository_unknown_falls_back_to_project
        ; Alcotest.test_case "blank repo falls through to keeper" `Quick test_workspace_blank_repo_param_uses_keeper
        ] )
    ; ( "rel_under"
      , [ Alcotest.test_case "normal nested"     `Quick test_rel_under_normal
        ; Alcotest.test_case "root base"         `Quick test_rel_under_root_base
        ; Alcotest.test_case "trailing slash"    `Quick test_rel_under_trailing_slash
        ; Alcotest.test_case "safe equals base"  `Quick test_rel_under_equal
        ] )
    ; ( "scan_dir"
      , [ Alcotest.test_case "respects max node cap" `Quick test_scan_dir_respects_max_nodes
        ; Alcotest.test_case "limit default" `Quick test_tree_node_limit_default
        ; Alcotest.test_case "limit invalid falls back" `Quick test_tree_node_limit_invalid_falls_back
        ; Alcotest.test_case "limit clamps low" `Quick test_tree_node_limit_clamps_low
        ; Alcotest.test_case "limit clamps high" `Quick test_tree_node_limit_clamps_high
        ; Alcotest.test_case "limit accepts valid" `Quick test_tree_node_limit_accepts_valid
        ; Alcotest.test_case "limit overflow clamps to max" `Quick test_tree_node_limit_overflow_clamps_to_max
        ; Alcotest.test_case "limit overflow with underscores clamps to max" `Quick test_tree_node_limit_overflow_with_underscores
        ; Alcotest.test_case "limit negative overflow clamps to 1" `Quick test_tree_node_limit_negative_overflow_clamps_low
        ; Alcotest.test_case "limit non-numeric falls back to default" `Quick test_tree_node_limit_non_numeric_still_default
        ; Alcotest.test_case "limit lone underscore is junk" `Quick test_tree_node_limit_lone_underscore_is_junk
        ; Alcotest.test_case "limit trailing underscore is junk" `Quick test_tree_node_limit_trailing_underscore_is_junk
        ; Alcotest.test_case "limit leading underscore is junk" `Quick test_tree_node_limit_leading_underscore_is_junk
        ; Alcotest.test_case "limit double underscore is junk" `Quick test_tree_node_limit_double_underscore_is_junk
        ; Alcotest.test_case "limit signed lone underscore is junk" `Quick test_tree_node_limit_signed_lone_underscore_is_junk
        ; Alcotest.test_case "failure observer increments metric" `Quick
            test_workspace_failure_observer_increments_metric
        ; Alcotest.test_case "log sanitizer bounds controlled text" `Quick
            test_workspace_log_value_sanitizer_bounds_controlled_text
        ; Alcotest.test_case "failure observer re-raises cancel" `Quick
            test_workspace_failure_observer_reraises_cancelled
        ] )
    ; ( "valid_git_ref"
      , [ Alcotest.test_case "main"              `Quick test_valid_ref_main
        ; Alcotest.test_case "40-char SHA"       `Quick test_valid_ref_sha
        ; Alcotest.test_case "origin/main"       `Quick test_valid_ref_path_form
        ; Alcotest.test_case "HEAD^"             `Quick test_valid_ref_caret
        ; Alcotest.test_case "feature+v2"        `Quick test_valid_ref_plus
        ; Alcotest.test_case "@{upstream}"       `Quick test_valid_ref_upstream_brace
        ; Alcotest.test_case "HEAD@{1}"          `Quick test_valid_ref_reflog_brace
        ; Alcotest.test_case "rejects -L1,9999"  `Quick test_valid_ref_rejects_leading_dash
        ; Alcotest.test_case "rejects empty"     `Quick test_valid_ref_rejects_empty
        ; Alcotest.test_case "rejects whitespace" `Quick test_valid_ref_rejects_whitespace
        ; Alcotest.test_case "rejects semicolon" `Quick test_valid_ref_rejects_semicolon
        ; Alcotest.test_case "rejects newline"   `Quick test_valid_ref_rejects_newline
        ; Alcotest.test_case "rejects oversize"  `Quick test_valid_ref_rejects_oversize
        ] )
    ]
