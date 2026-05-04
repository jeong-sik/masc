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
    ]
