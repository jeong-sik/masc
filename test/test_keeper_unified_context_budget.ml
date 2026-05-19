open Alcotest

module KEC = Masc_mcp.Keeper_exec_context
module OMR = Masc_mcp.Cascade_runtime
module UT = Masc_mcp.Keeper_unified_turn

let make_meta name : Masc_mcp.Keeper_types.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("test-trace-" ^ name));
        ("goal", `String "test goal");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let minimal_meta : Masc_mcp.Keeper_types.keeper_meta = make_meta "test-keeper"

let test_pure_local_labels_detection () =
  check
    bool
    "ollama-only cascade is pure local"
    true
    (OMR.labels_are_pure_local [ "ollama:qwen3.5:35b-a3b-nvfp4" ]);
  check
    bool
    "mixed cascade is not pure local"
    false
    (OMR.labels_are_pure_local [ "glm:glm-5.1"; "ollama:qwen3.5:35b-a3b-nvfp4" ])
;;

let test_clamp_context_for_pure_local_labels () =
  let local_floor = Env_config.ContextCompact.small_local_floor in
  check
    int
    "pure local max_context gets capped"
    local_floor
    (OMR.clamp_context_for_pure_local_labels
       ~labels:[ "ollama:qwen3.5:35b-a3b-nvfp4" ]
       ~max_context:262_144);
  check
    int
    "mixed cascade keeps raw context"
    262_144
    (OMR.clamp_context_for_pure_local_labels
       ~labels:[ "glm:glm-5.1"; "ollama:qwen3.5:35b-a3b-nvfp4" ]
       ~max_context:262_144)
;;

let test_resolved_max_context_for_turn_uses_primary_budget () =
  let labels = [ "glm:glm-5.1"; "ollama:qwen3.5:35b-a3b-nvfp4" ] in
  let expected = OMR.resolve_primary_max_context labels in
  check
    int
    "turn budget follows primary available model"
    expected
    (UT.resolved_max_context_for_turn ~meta:minimal_meta labels)
;;

let test_max_context_resolution_separates_override_and_effective_budget () =
  let labels = [ "unknown:model" ] in
  let resolution =
    KEC.resolve_max_context_resolution ~requested_override:(Some 1_000_000) labels
  in
  check
    int
    "primary budget uses fallback context window"
    Masc_mcp.Cascade_runtime.fallback_context_window
    resolution.primary_budget;
  check int "turn budget preserves requested override" 1_000_000 resolution.turn_budget;
  check
    int
    "effective budget caps to primary budget"
    resolution.primary_budget
    resolution.effective_budget
;;

let test_resolved_max_context_for_turn_uses_effective_budget () =
  let labels = [ "unknown:model" ] in
  let meta = { minimal_meta with max_context_override = Some 1_000_000 } in
  let resolution =
    KEC.resolve_max_context_resolution
      ~requested_override:meta.max_context_override
      labels
  in
  check
    int
    "turn dispatch budget is capped to effective budget"
    resolution.effective_budget
    (UT.resolved_max_context_for_turn ~meta labels)
;;

let () =
  run
    "keeper_unified_context_budget"
    [ ( "context_budget"
      , [ test_case "pure local label detection" `Quick test_pure_local_labels_detection
        ; test_case
            "pure local context clamp"
            `Quick
            test_clamp_context_for_pure_local_labels
        ; test_case
            "turn context budget uses primary model"
            `Quick
            test_resolved_max_context_for_turn_uses_primary_budget
        ; test_case
            "max_context resolution separates override and effective budget"
            `Quick
            test_max_context_resolution_separates_override_and_effective_budget
        ; test_case
            "resolved max_context dispatch uses effective budget"
            `Quick
            test_resolved_max_context_for_turn_uses_effective_budget
        ] )
    ]
;;
