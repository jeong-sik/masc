open Alcotest

module Profile = Masc_mcp.Keeper_cascade_profile

(* Names that must round-trip [of_string_opt] -> [to_string] without
   collapsing to default. Pre-2026-04-17 only the first 6 worked; the
   rest silently fell back to Keeper_unified, so cascade.json presets
   like vendor_mix_balanced were dead config. *)
let active_names =
  [ "default";
    "keeper_unified";
    "governance_judge";
    "operator_judge";
    "sangsu";
    "local_only";
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

let () =
  run "keeper_cascade_profile"
    [ ( "ssot",
        [ test_case "active names round-trip" `Quick test_round_trip;
          test_case "known_cascades covers active" `Quick test_known_cascades_covers_active;
          test_case "legacy aliases collapse" `Quick test_legacy_aliases_collapse_to_keeper_unified;
          test_case "unknown falls back to default" `Quick test_unknown_falls_back_to_default ] )
    ]
