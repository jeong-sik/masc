open Alcotest
open Masc_mcp

module Search = Cp_search_fabric

let test_readiness_blocks_on_incomplete_upstream () =
  let upstreams =
    [
      { Search.operation_id = "op-normalize"; status = "active"; checkpoint_ref = None };
      { Search.operation_id = "op-curate"; status = "completed"; checkpoint_ref = None };
    ]
  in
  match Search.readiness_for_operation ~upstreams with
  | Search.Ready -> fail "expected blocked readiness"
  | Search.Blocked blockers ->
      check int "one blocker" 1 (List.length blockers);
      check string "blocked op id" "op-normalize" (List.hd blockers).Search.operation_id

let test_readiness_accepts_checkpointed_upstream () =
  let upstreams =
    [
      {
        Search.operation_id = "op-normalize";
        status = "active";
        checkpoint_ref = Some "ckpt-1";
      };
    ]
  in
  match Search.readiness_for_operation ~upstreams with
  | Search.Ready -> ()
  | Search.Blocked _ -> fail "checkpointed upstream should be ready"

let test_scoring_prefers_stage_matched_candidate () =
  let operation : Search.operation_descriptor =
    {
      operation_id = Some "op-verify";
      objective = "Verify and quarantine research findings";
      assigned_unit_id = Some "platoon-research";
      workload_profile = "research_pipeline";
      stage = Some "verify";
      artifact_scope = [];
      depends_on_operation_ids = [];
      created_at = "2026-03-08T00:00:00Z";
    }
  in
  let candidates =
    [
      {
        Search.unit_id = "squad-verify";
        label = "Verify Squad";
        capability_profile = [ "verify"; "research"; "research_pipeline" ];
        active_operation_cap = 4;
        active_operations = 1;
        current_assignment = false;
      };
      {
        Search.unit_id = "squad-normalize";
        label = "Normalize Squad";
        capability_profile = [ "normalize"; "research"; "research_pipeline" ];
        active_operation_cap = 4;
        active_operations = 1;
        current_assignment = false;
      };
    ]
  in
  let ranked = Search.score_candidates ~store:Search.default_store ~operation ~candidates in
  match ranked with
  | best :: second :: _ ->
      check string "best unit" "squad-verify" best.Search.unit_id;
      check bool "best score higher"
        true
        (best.Search.breakdown.total > second.Search.breakdown.total)
  | _ -> fail "expected ranked candidates"

let test_scoring_prefers_artifact_local_coding_candidate () =
  let operation : Search.operation_descriptor =
    {
      operation_id = Some "op-implement";
      objective = "Patch coding_task search defaults in command plane";
      assigned_unit_id = Some "platoon-runtime";
      workload_profile = "coding_task";
      stage = Some "implement";
      artifact_scope = [ "lib/command_plane_v2.ml"; "test/test_command_plane_v2.ml" ];
      depends_on_operation_ids = [];
      created_at = "2026-03-08T00:00:00Z";
    }
  in
  let candidates =
    [
      {
        Search.unit_id = "squad-ocaml-cp";
        label = "OCaml Command Plane Squad";
        capability_profile =
          [
            "role:implementer";
            "lang:ocaml";
            "artifact:lib/command_plane_v2.ml";
            "artifact:test/test_command_plane_v2.ml";
            "tool:dune";
            "runtime:local64";
            "model:auto";
          ];
        active_operation_cap = 4;
        active_operations = 1;
        current_assignment = false;
      };
      {
        Search.unit_id = "squad-docs";
        label = "Docs Squad";
        capability_profile =
          [ "role:documenter"; "artifact:docs/SEARCH-FABRIC-V1.md"; "runtime:shared" ];
        active_operation_cap = 4;
        active_operations = 1;
        current_assignment = false;
      };
    ]
  in
  let ranked = Search.score_candidates ~store:Search.default_store ~operation ~candidates in
  match ranked with
  | best :: second :: _ ->
      check string "best unit" "squad-ocaml-cp" best.Search.unit_id;
      check bool "artifact locality contributes"
        true
        (best.Search.breakdown.artifact_locality > second.Search.breakdown.artifact_locality);
      check bool "runtime fit contributes" true
        (best.Search.breakdown.runtime_fit > second.Search.breakdown.runtime_fit);
      check bool "cost efficiency contributes" true
        (best.Search.breakdown.cost_efficiency > second.Search.breakdown.cost_efficiency)
  | _ -> fail "expected ranked candidates"

let test_should_rebalance_requires_margin () =
  let current =
    {
      Search.unit_id = "squad-a";
      label = "Squad A";
      routing_reason = "current";
      breakdown =
        {
          Search.capability_match = 20.0;
          artifact_locality = 10.0;
          intent_successor = 0.0;
          verification_readiness = 0.0;
          runtime_fit = 10.0;
          posterior_success = 10.0;
          capacity_headroom = 5.0;
          cost_efficiency = 2.5;
          queue_age = 2.5;
          stickiness = 5.0;
          total = 60.0;
        };
    }
  in
  let small_gain =
    {
      current with
      Search.unit_id = "squad-b";
      breakdown = { current.Search.breakdown with total = 70.0 };
    }
  in
  let large_gain =
    {
      current with
      Search.unit_id = "squad-c";
      breakdown = { current.Search.breakdown with total = 76.0 };
    }
  in
  check bool "10 point gain is not enough" false
    (Search.should_rebalance ~current ~best:small_gain ~min_gain:15.0);
  check bool "16 point gain moves" true
    (Search.should_rebalance ~current ~best:large_gain ~min_gain:15.0)

let test_stats_roundtrip () =
  let tmp = Filename.temp_file "cp_search_fabric" ".json" in
  let store =
    Search.default_store
    |> Search.record_success ~unit_id:"squad-verify"
         ~workload_profile:"coding_task" ~stage:(Some "verify")
    |> Search.record_failure ~unit_id:"squad-verify"
         ~workload_profile:"coding_task" ~stage:(Some "verify")
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with _ -> ())
    (fun () ->
      Search.save_store tmp store;
      let reloaded = Search.load_store tmp in
      let stats =
        Search.lookup_stats reloaded ~unit_id:"squad-verify"
          ~workload_profile:"coding_task" ~stage:(Some "verify")
      in
      check (float 0.01) "alpha" 2.0 stats.Search.alpha;
      check (float 0.01) "beta" 2.0 stats.Search.beta)

let test_legacy_generic_stats_upgrade_to_coding_task () =
  let legacy_store =
    [
      {
        Search.unit_id = "squad-verify";
        workload_profile = "generic";
        stage = Some "verify";
        alpha = 2.0;
        beta = 1.0;
        updated_at = "2026-03-08T00:00:00Z";
      };
    ]
  in
  let upgraded =
    Search.record_success legacy_store ~unit_id:"squad-verify"
      ~workload_profile:"coding_task" ~stage:(Some "verify")
  in
  let stats =
    Search.lookup_stats upgraded ~unit_id:"squad-verify"
      ~workload_profile:"coding_task" ~stage:(Some "verify")
  in
  check string "workload upgraded" "coding_task" stats.Search.workload_profile;
  check (float 0.01) "alpha increments" 3.0 stats.Search.alpha;
  check (float 0.01) "beta preserved" 1.0 stats.Search.beta

let test_legacy_generic_stage_upgrades_to_unset () =
  let legacy_store =
    [
      {
        Search.unit_id = "squad-plan";
        workload_profile = "coding_task";
        stage = Some "generic";
        alpha = 2.0;
        beta = 1.0;
        updated_at = "2026-03-08T00:00:00Z";
      };
    ]
  in
  let stats =
    Search.lookup_stats legacy_store ~unit_id:"squad-plan"
      ~workload_profile:"coding_task" ~stage:None
  in
  check (option string) "legacy generic stage normalizes to unset" None
    stats.Search.stage;
  check (float 0.01) "alpha preserved" 2.0 stats.Search.alpha;
  check (float 0.01) "beta preserved" 1.0 stats.Search.beta

let () =
  run "Cp_search_fabric"
    [
      ( "readiness",
        [
          test_case "blocks on incomplete upstream" `Quick
            test_readiness_blocks_on_incomplete_upstream;
          test_case "accepts checkpointed upstream" `Quick
            test_readiness_accepts_checkpointed_upstream;
        ] );
      ( "scoring",
        [
          test_case "prefers stage matched candidate" `Quick
            test_scoring_prefers_stage_matched_candidate;
          test_case "prefers artifact local coding candidate" `Quick
            test_scoring_prefers_artifact_local_coding_candidate;
          test_case "rebalance requires margin" `Quick
            test_should_rebalance_requires_margin;
        ] );
      ( "stats",
        [
          test_case "roundtrip" `Quick test_stats_roundtrip;
          test_case "legacy generic stats upgrade to coding_task" `Quick
            test_legacy_generic_stats_upgrade_to_coding_task;
          test_case "legacy generic stage upgrades to unset" `Quick
            test_legacy_generic_stage_upgrades_to_unset;
        ] );
    ]
