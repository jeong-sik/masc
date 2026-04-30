open Alcotest

module Profile = Masc_mcp.Keeper_cascade_profile

(* Only concrete profile variants round-trip through [of_string_opt] ->
   [to_string]. Legacy aliases are logical route names, not profile names. *)
let variant_names = [ "big_three"; "tool_rerank" ]

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

let test_round_trip () =
  List.iter
    (fun name ->
      let canon = Profile.canonicalize name in
      check string ("round-trip " ^ name) name canon)
    variant_names

let test_known_cascades_covers_variants () =
  List.iter
    (fun name ->
      let listed = List.mem name Profile.known_cascades in
      check bool ("known_cascades contains " ^ name) true listed)
    variant_names

let test_legacy_aliases_follow_keeper_fallback_without_catalog () =
  let aliases = [ "oas-keeper_unified"; "coding_first"; "oas-coding_first";
                  "keeper_turn"; "keeper_reply"; "default"; "keeper_unified";
                  "sangsu"; "local_mlx_vlm_qwen36";
                  "nick0cave"; "capacity_queue_trio"; "vendor_mix_balanced";
                  "cost_tier_ladder"; "oauth_cli_rotate"; "quality_sticky_glm51";
                  "tool_use_strict"; "resilient_breaker"; "" ] in
  List.iter
    (fun raw ->
      let canon = Profile.canonicalize_with_catalog ~catalog:[] raw in
      check string ("alias " ^ raw ^ " -> fallback") "big_three" canon)
    aliases

let test_logical_route_names_are_not_profile_variants () =
  check (option (testable (fun fmt _ -> Format.fprintf fmt "<profile>") (=)))
    "keeper_unified is not a built-in profile"
    None
    (Profile.of_string_opt "keeper_unified");
  check (option (testable (fun fmt _ -> Format.fprintf fmt "<profile>") (=)))
    "tool_use_strict is not a built-in profile"
    None
    (Profile.of_string_opt "tool_use_strict");
  check (option (testable (fun fmt _ -> Format.fprintf fmt "<profile>") (=)))
    "resilient_breaker is not a built-in profile"
    None
    (Profile.of_string_opt "resilient_breaker");
  check (option (testable (fun fmt _ -> Format.fprintf fmt "<profile>") (=)))
    "local_only is not a built-in profile"
    None
    (Profile.of_string_opt "local_only");
  check (option (testable (fun fmt _ -> Format.fprintf fmt "<profile>") (=)))
    "local_recovery is not a built-in profile"
    None
    (Profile.of_string_opt "local_recovery")

let test_unknown_falls_back_to_default () =
  check (option (testable (fun fmt _ -> Format.fprintf fmt "<profile>") (=)))
    "unknown returns None from of_string_opt"
    None
    (Profile.of_string_opt "definitely_not_a_real_cascade_xyz");
  check string "canonicalize forces fallback to big_three"
    "big_three"
    (Profile.canonicalize "definitely_not_a_real_cascade_xyz")

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
        [
          "custom_live";
          "default";
          "governance_judge";
          "keeper_unified";
          "tool_rerank";
          "tool_use_strict";
        ]
        catalog;
      check (list string) "keeper catalog excludes system-only cascades"
        [ "custom_live"; "default"; "keeper_unified"; "tool_use_strict" ]
        (Profile.keeper_catalog_names ~config_path:path ());
      check (list string) "system catalog follows explicit metadata"
        [ "governance_judge"; "tool_rerank" ]
        (Profile.system_catalog_names ~config_path:path ());
      check string "dynamic live profile survives canonicalization"
        "custom_live"
        (Profile.canonicalize_with_catalog ~catalog "custom_live");
      check string "keeper_unified catalog profile survives canonicalization"
        "keeper_unified"
        (Profile.canonicalize_with_catalog ~catalog "keeper_unified");
      check string "tool_use_strict catalog profile survives canonicalization"
        "tool_use_strict"
        (Profile.canonicalize_with_catalog ~catalog "tool_use_strict");
      check string "dynamic live profile requires exact match"
        "custom_live"
        (Profile.canonicalize_with_catalog ~catalog "Custom_Live");
      check string "unknown live profile still falls back"
        "custom_live"
        (Profile.canonicalize_with_catalog ~catalog "missing_profile"))

let test_resolve_live_with_catalog_requires_active_membership () =
  with_temp_config
    {|
      {
        "default_models": ["ollama:auto"],
        "custom_live_models": ["ollama:auto"],
        "keeper_unified_models": ["ollama:auto"],
        "tool_use_strict_models": ["ollama:auto"]
      }
    |}
    (fun path ->
      let catalog = Profile.catalog_names ~config_path:path () in
      check string "active custom profile survives live resolution"
        "custom_live"
        (Profile.resolve_live_with_catalog ~catalog "custom_live");
      check string "keeper_unified catalog profile survives live resolution"
        "keeper_unified"
        (Profile.resolve_live_with_catalog ~catalog "keeper_unified");
      check string "tool_use_strict catalog profile survives live resolution"
        "tool_use_strict"
        (Profile.resolve_live_with_catalog ~catalog "tool_use_strict");
      check string "legacy alias resolves through active catalog fallback"
        "custom_live"
        (Profile.resolve_live_with_catalog ~catalog "oas-keeper_unified");
      check string "inactive built-in profile falls back to default"
        "custom_live"
        (Profile.resolve_live_with_catalog ~catalog "vendor_mix_balanced");
      check string "unknown profile falls back to default"
        "custom_live"
        (Profile.resolve_live_with_catalog ~catalog "missing_profile"))

let test_routes_resolve_logical_uses_to_configured_profiles () =
  with_temp_config
    {|
      {
        "big_three_models": ["codex_cli:auto"],
        "custom_live_models": ["gemini_cli:auto"],
        "tool_rerank_models": ["codex_cli:auto"],
        "tool_rerank_keeper_assignable": false,
        "routes": {
          "governance_judge": "custom_live",
          "operator_judge": "big_three",
          "llm_rerank": "tool_rerank"
        }
      }
    |}
    (fun path ->
      check string "governance route target"
        "custom_live"
        (Profile.cascade_name_for_use ~config_path:path Profile.Governance_judge);
      check string "operator route target"
        "big_three"
        (Profile.cascade_name_for_use ~config_path:path Profile.Operator_judge);
      check string "tool rerank route target"
        "tool_rerank"
        (Profile.cascade_name_for_use ~config_path:path Profile.Tool_rerank_use);
      check (list string) "route targets are discovered"
        [ "big_three"; "custom_live"; "tool_rerank" ]
        (Profile.configured_route_targets ~config_path:path ()))

let test_missing_route_uses_catalog_fallback_not_logical_name () =
  with_temp_config
    {|
      {
        "alpha_models": ["gemini_cli:auto"],
        "tool_rerank_models": ["codex_cli:auto"],
        "tool_rerank_keeper_assignable": false
      }
    |}
    (fun path ->
      check string "missing governance route uses keeper-assignable profile"
        "alpha"
        (Profile.cascade_name_for_use ~config_path:path Profile.Governance_judge);
      check string "missing rerank route still prefers tool_rerank when present"
        "tool_rerank"
        (Profile.cascade_name_for_use ~config_path:path Profile.Tool_rerank_use))

let test_missing_system_route_prefers_system_only_catalog_profile () =
  with_temp_config
    {|
      {
        "alpha_models": ["gemini_cli:auto"],
        "short_scoring_models": ["codex_cli:auto"],
        "short_scoring_keeper_assignable": false
      }
    |}
    (fun path ->
      check string "system route uses system-only catalog profile"
        "short_scoring"
        (Profile.cascade_name_for_use ~config_path:path Profile.Tool_rerank_use))

let test_catalog_read_failures_do_not_fallback_to_hardcoded_names () =
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

let () =
  run "keeper_cascade_profile"
    [ ( "ssot",
        [ test_case "active names round-trip" `Quick test_round_trip;
          test_case "known_cascades covers active" `Quick test_known_cascades_covers_variants;
          test_case "legacy aliases follow fallback" `Quick
            test_legacy_aliases_follow_keeper_fallback_without_catalog;
          test_case "logical route names are not profile variants" `Quick
            test_logical_route_names_are_not_profile_variants;
          test_case "unknown falls back to default" `Quick test_unknown_falls_back_to_default;
          test_case "catalog_names follow live config" `Quick test_catalog_names_follow_live_config;
          test_case "resolve_live_with_catalog requires active membership" `Quick
            test_resolve_live_with_catalog_requires_active_membership;
          test_case "routes resolve logical uses" `Quick
            test_routes_resolve_logical_uses_to_configured_profiles;
          test_case "missing route uses catalog fallback" `Quick
            test_missing_route_uses_catalog_fallback_not_logical_name;
          test_case "missing system route uses system-only fallback" `Quick
            test_missing_system_route_prefers_system_only_catalog_profile;
          test_case "catalog read failures stay empty" `Quick
            test_catalog_read_failures_do_not_fallback_to_hardcoded_names ] )
    ]
