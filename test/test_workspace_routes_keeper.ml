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

let project = "/repo"
let playground_root = "/playgrounds/<keeper>"

let no_lookup _ = None
let always_missing _ = false

let lookup_for known name = if name = known then Some playground_root else None
let exists_only path expected = path = expected

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

(* ─── source_header ─────────────────────────────────────────────── *)

let header_value headers =
  match headers with
  | [(k, v)] when k = "X-Workspace-Source" -> v
  | _ -> Alcotest.fail "expected single X-Workspace-Source header"

let test_header_project () =
  let v = header_value (W.source_header `Project) in
  Alcotest.(check string) "project" "project" v

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
        ; Alcotest.test_case "playground"        `Quick test_header_playground
        ; Alcotest.test_case "playground missing" `Quick test_header_playground_missing
        ; Alcotest.test_case "keeper unknown"    `Quick test_header_keeper_unknown
        ] )
    ; ( "rel_under"
      , [ Alcotest.test_case "normal nested"     `Quick test_rel_under_normal
        ; Alcotest.test_case "root base"         `Quick test_rel_under_root_base
        ; Alcotest.test_case "trailing slash"    `Quick test_rel_under_trailing_slash
        ; Alcotest.test_case "safe equals base"  `Quick test_rel_under_equal
        ] )
    ; ( "valid_git_ref"
      , [ Alcotest.test_case "main"              `Quick test_valid_ref_main
        ; Alcotest.test_case "40-char SHA"       `Quick test_valid_ref_sha
        ; Alcotest.test_case "origin/main"       `Quick test_valid_ref_path_form
        ; Alcotest.test_case "HEAD^"             `Quick test_valid_ref_caret
        ; Alcotest.test_case "rejects -L1,9999"  `Quick test_valid_ref_rejects_leading_dash
        ; Alcotest.test_case "rejects empty"     `Quick test_valid_ref_rejects_empty
        ; Alcotest.test_case "rejects whitespace" `Quick test_valid_ref_rejects_whitespace
        ; Alcotest.test_case "rejects semicolon" `Quick test_valid_ref_rejects_semicolon
        ; Alcotest.test_case "rejects newline"   `Quick test_valid_ref_rejects_newline
        ; Alcotest.test_case "rejects oversize"  `Quick test_valid_ref_rejects_oversize
        ] )
    ]
