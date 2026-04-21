open Alcotest

module Profile = Masc_mcp.Keeper_cascade_profile

(* Names that must round-trip [of_string_opt] -> [to_string] without
   collapsing to default. Pre-2026-04-17 only the first 6 worked; the
   rest silently fell back to Keeper_unified, so cascade.json presets
   like vendor_mix_balanced were dead config. *)
let active_names =
  [ "default";
    "keeper_unified";
    "sangsu";
    "local_only";
    "local_mlx_vlm_qwen36";
    "local_recovery";
    "tool_rerank";
    "nick0cave";
    "capacity_queue_trio";
    "vendor_mix_balanced";
    "cost_tier_ladder";
    "oauth_cli_rotate";
    "quality_sticky_glm51";
    "tool_use_strict";
    "resilient_breaker" ]

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
    active_names

let test_known_cascades_covers_active () =
  List.iter
    (fun name ->
      let listed = List.mem name Profile.known_cascades in
      check bool ("known_cascades contains " ^ name) true listed)
    active_names

let test_legacy_aliases_collapse_to_keeper_unified () =
  let aliases = [ "oas-keeper_unified"; "coding_first"; "oas-coding_first";
                  "keeper_turn"; "keeper_reply"; "" ] in
  List.iter
    (fun raw ->
      let canon = Profile.canonicalize raw in
      check string ("alias " ^ raw ^ " -> keeper_unified") "keeper_unified" canon)
    aliases

let test_unknown_falls_back_to_default () =
  check (option (testable (fun fmt _ -> Format.fprintf fmt "<profile>") (=)))
    "unknown returns None from of_string_opt"
    None
    (Profile.of_string_opt "definitely_not_a_real_cascade_xyz");
  check string "canonicalize forces fallback to keeper_unified"
    "keeper_unified"
    (Profile.canonicalize "definitely_not_a_real_cascade_xyz")

let test_catalog_names_follow_live_config () =
  with_temp_config
    {|
      {
        "default_models": ["ollama:qwen3.5:35b-a3b-nvfp4"],
        "custom_live_models": ["ollama:qwen3.5:35b-a3b-nvfp4"],
        "tool_rerank_temperature": 0.0,
        "tool_rerank_max_tokens": 200,
        "tool_rerank_keeper_assignable": false,
        "governance_judge_models": ["ollama:qwen3.5:35b-a3b-nvfp4"],
        "governance_judge_keeper_assignable": false
      }
    |}
    (fun path ->
      let catalog = Profile.catalog_names ~config_path:path () in
      check (list string) "catalog_names follows cascade schema keys"
        [ "custom_live"; "default"; "governance_judge"; "tool_rerank" ]
        catalog;
      check (list string) "keeper catalog excludes system-only cascades"
        [ "custom_live"; "default" ]
        (Profile.keeper_catalog_names ~config_path:path ());
      check (list string) "system catalog follows explicit metadata"
        [ "governance_judge"; "tool_rerank" ]
        (Profile.system_catalog_names ~config_path:path ());
      check string "dynamic live profile survives canonicalization"
        "custom_live"
        (Profile.canonicalize_with_catalog ~catalog "custom_live");
      check string "dynamic live profile requires exact match"
        "keeper_unified"
        (Profile.canonicalize_with_catalog ~catalog "Custom_Live");
      check string "unknown live profile still falls back"
        "keeper_unified"
        (Profile.canonicalize_with_catalog ~catalog "missing_profile"))

let test_resolve_live_with_catalog_requires_active_membership () =
  with_temp_config
    {|
      {
        "default_models": ["ollama:qwen3.5:35b-a3b-nvfp4"],
        "custom_live_models": ["ollama:qwen3.5:35b-a3b-nvfp4"]
      }
    |}
    (fun path ->
      let catalog = Profile.catalog_names ~config_path:path () in
      check string "active custom profile survives live resolution"
        "custom_live"
        (Profile.resolve_live_with_catalog ~catalog "custom_live");
      check string "legacy alias resolves through active default"
        "keeper_unified"
        (Profile.resolve_live_with_catalog ~catalog "oas-keeper_unified");
      check string "inactive built-in profile falls back to default"
        "keeper_unified"
        (Profile.resolve_live_with_catalog ~catalog "vendor_mix_balanced");
      check string "unknown profile falls back to default"
        "keeper_unified"
        (Profile.resolve_live_with_catalog ~catalog "missing_profile"))

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
          test_case "known_cascades covers active" `Quick test_known_cascades_covers_active;
          test_case "legacy aliases collapse" `Quick test_legacy_aliases_collapse_to_keeper_unified;
          test_case "unknown falls back to default" `Quick test_unknown_falls_back_to_default;
          test_case "catalog_names follow live config" `Quick test_catalog_names_follow_live_config;
          test_case "resolve_live_with_catalog requires active membership" `Quick
            test_resolve_live_with_catalog_requires_active_membership;
          test_case "catalog read failures stay empty" `Quick
            test_catalog_read_failures_do_not_fallback_to_hardcoded_names ] )
    ]
