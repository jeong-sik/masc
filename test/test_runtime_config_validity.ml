open Alcotest
open Masc_mcp

let empty_env _name = None

let parse_or_fail content =
  match Keeper_toml_loader.parse_toml content with
  | Ok doc -> doc
  | Error msg -> failf "TOML parse failed: %s" msg

let rec repo_root_from dir =
  let dune_project = Filename.concat dir "dune-project" in
  if Sys.file_exists dune_project then dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then
      failf "unable to locate repo root from cwd=%s" (Sys.getcwd ())
    else repo_root_from parent

let repo_root () = repo_root_from (Sys.getcwd ())

let test_runtime_json_not_in_repo_config () =
  let path = Filename.concat (repo_root ()) "config/runtime.json" in
  check bool "retired runtime.json absent" false (Sys.file_exists path)

let test_toml_catalog_resolves_lifecycle_keys () =
  let doc =
    parse_or_fail
      "[lifecycle]\n\
       self_preservation_ratio = 0.4\n\
       self_preservation_min = 2\n\
       dead_ttl_sec = 86400\n\
       paused_cleanup_ttl_sec = 604800\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied lifecycle overrides" 4 count;
  check (option string) "self preservation ratio" (Some "0.4")
    (List.assoc_opt "MASC_KEEPER_SELF_PRESERVATION_RATIO" overrides);
  check (option string) "self preservation min" (Some "2")
    (List.assoc_opt "MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES" overrides);
  check (option string) "dead ttl" (Some "86400")
    (List.assoc_opt "MASC_KEEPER_DEAD_TTL_SEC" overrides);
  check (option string) "paused cleanup ttl" (Some "604800")
    (List.assoc_opt "MASC_KEEPER_PAUSED_CLEANUP_TTL_SEC" overrides)

let () =
  run "runtime_config_validity"
    [ ( "runtime TOML gate",
        [ test_case "runtime.json is not a repo config source" `Quick
            test_runtime_json_not_in_repo_config;
          test_case
            "lifecycle TOML keys resolve through the declarative catalog"
            `Quick test_toml_catalog_resolves_lifecycle_keys ] )
    ]
