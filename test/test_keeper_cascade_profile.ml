open Alcotest

module Profile = Masc_mcp.Keeper_cascade_profile

(* RFC-0041: catalog (cascade.json) is the only source of truth for cascade
   profile names.  This suite exercises the catalog-driven resolution paths
   and the boot-time invariant that the catalog must not be empty when the
   helpers are reached at runtime. *)

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let with_temp_config contents f =
  let dir = Filename.temp_file "keeper-cascade-profile-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let path = Filename.concat dir "cascade.json" in
  write_file path contents;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f path)

let test_catalog_names_follow_live_config () =
  with_temp_config
    {|
      {
        "default_models": ["ollama:auto"],
        "custom_live_models": ["ollama:auto"],
        "keeper_unified_models": ["ollama:auto"],
        "tool_use_strict_models": ["ollama:auto"],
        "tool_rerank_temperature": 0.0,
        "tool_rerank_max_tokens": 200,
        "tool_rerank_keeper_assignable": false,
        "governance_judge_models": ["ollama:auto"],
        "governance_judge_keeper_assignable": false
      }
    |}
    (fun path ->
      let catalog = Profile.catalog_names ~config_path:path () in
      check (list string) "catalog_names follows cascade schema keys"
        [ "custom_live"; "tool_rerank" ]
        catalog;
      check (list string) "keeper catalog excludes system-only cascades"
        [ "custom_live" ]
        (Profile.keeper_catalog_names ~config_path:path ());
      check (list string) "system catalog follows explicit metadata"
        [ "tool_rerank" ]
        (Profile.system_catalog_names ~config_path:path ());
      check string "exact catalog name passes through canonicalize"
        "custom_live"
        (Profile.canonicalize_with_catalog ~catalog "custom_live");
      check string "logical alias resolves through routes"
        "custom_live"
        (Profile.canonicalize_with_catalog ~catalog "keeper_unified");
      check string "operator-defined raw passes through trimmed"
        "missing_profile"
        (Profile.canonicalize_with_catalog ~catalog "missing_profile"))

let test_resolve_live_with_catalog_requires_active_membership () =
  with_temp_config
    {|
      {
        "default_models": ["ollama:auto"],
        "custom_live_models": ["ollama:auto"]
      }
    |}
    (fun path ->
      let catalog = Profile.catalog_names ~config_path:path () in
      check string "active custom profile survives live resolution"
        "custom_live"
        (Profile.resolve_live_with_catalog ~catalog "custom_live");
      check string "logical alias resolves through catalog fallback"
        "custom_live"
        (Profile.resolve_live_with_catalog ~catalog "keeper_unified");
      check string "absent profile falls to first catalog entry"
        "custom_live"
        (Profile.resolve_live_with_catalog ~catalog "missing_profile"))

let test_routes_resolve_logical_uses_to_configured_profiles () =
  with_temp_config
    {|
      {
        "alpha_models": ["codex_cli:auto"],
        "custom_live_models": ["gemini_cli:auto"],
        "beta_models": ["codex_cli:auto"],
        "beta_keeper_assignable": false,
        "routes": {
          "governance_judge": "custom_live",
          "operator_judge": "alpha",
          "llm_rerank": "beta"
        }
      }
    |}
    (fun path ->
      check string "governance route target"
        "custom_live"
        (Profile.cascade_name_for_use ~config_path:path Profile.Governance_judge);
      check string "operator route target"
        "alpha"
        (Profile.cascade_name_for_use ~config_path:path Profile.Operator_judge);
      check string "tool rerank route target"
        "beta"
        (Profile.cascade_name_for_use ~config_path:path Profile.Tool_rerank_use);
      check (list string) "route targets are discovered"
        [ "alpha"; "beta"; "custom_live" ]
        (Profile.configured_route_targets ~config_path:path ()))

let test_missing_route_falls_back_to_first_catalog_entry () =
  with_temp_config
    {|
      {
        "alpha_models": ["gemini_cli:auto"],
        "tool_rerank_models": ["codex_cli:auto"],
        "tool_rerank_keeper_assignable": false
      }
    |}
    (fun path ->
      check string "missing governance route falls to first catalog entry"
        "alpha"
        (Profile.cascade_name_for_use ~config_path:path Profile.Governance_judge))

let test_catalog_read_failures_stay_empty () =
  let missing = Filename.concat (Filename.get_temp_dir_name ()) "missing-cascade.json" in
  check (list string) "catalog_names stays empty on read failure"
    []
    (Profile.catalog_names ~config_path:missing ());
  check (list string) "keeper catalog stays empty on read failure"
    []
    (Profile.keeper_catalog_names ~config_path:missing ());
  check (list string) "system catalog stays empty on read failure"
    []
    (Profile.system_catalog_names ~config_path:missing ())

let test_empty_catalog_raises_boot_invariant () =
  (* RFC-0041: when the catalog is empty, runtime callers must never reach
     [fallback_name_for_catalog] — boot-time validation is the upstream
     gate. The helper raises [Failure] to surface the invariant violation
     loudly when the gate is bypassed. *)
  check_raises "fallback_name_for_catalog raises on empty catalog"
    (Failure
       "cascade catalog empty when resolving logical use \"keeper_turn\" — \
        Cascade_catalog_runtime.validate_path_result should have rejected \
        keeper boot before this is reached")
    (fun () ->
      let _ =
        Profile.canonicalize_with_catalog ~catalog:[] "" in
      ())

let () =
  run "keeper_cascade_profile"
    [ ( "catalog_ssot",
        [ test_case "catalog_names follow live config" `Quick
            test_catalog_names_follow_live_config;
          test_case "resolve_live_with_catalog requires active membership" `Quick
            test_resolve_live_with_catalog_requires_active_membership;
          test_case "routes resolve logical uses" `Quick
            test_routes_resolve_logical_uses_to_configured_profiles;
          test_case "missing route falls to first catalog entry" `Quick
            test_missing_route_falls_back_to_first_catalog_entry;
          test_case "catalog read failures stay empty" `Quick
            test_catalog_read_failures_stay_empty;
          test_case "empty catalog raises boot invariant" `Quick
            test_empty_catalog_raises_boot_invariant ] )
    ]
