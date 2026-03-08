open Masc_mcp

let test_build_worker_plans_is_deterministic () =
  let run_id = "swarm-live-proof" in
  let plans = Agent_swarm_live_harness.build_worker_plans run_id in
  Alcotest.(check int) "twelve workers" 12 (List.length plans);
  let names =
    plans
    |> List.map (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name)
  in
  Alcotest.(check string) "first worker"
    "swarm-discover-official-swarm-live-proof" (List.hd names);
  Alcotest.(check string) "last worker"
    "swarm-audit-reviews-swarm-live-proof" (List.hd (List.rev names));
  let finals =
    plans
    |> List.map (fun (plan : Agent_swarm_live_harness.worker_plan) ->
           plan.final_marker)
  in
  Alcotest.(check bool) "discover official final present" true
    (List.mem "FINAL_MARKER[swarm-live-proof:discover:official]" finals);
  Alcotest.(check bool) "audit reviews final present" true
    (List.mem "FINAL_MARKER[swarm-live-proof:audit:reviews]" finals)

let test_manifest_respects_provider_override () =
  let cfg : Agent_swarm_live_harness.config =
    {
      run_id = "demo-run";
      masc_url = "http://127.0.0.1:9999";
      provider_base_url = "http://127.0.0.1:3034";
      model_id = "qwen3.5-35b-a3b-ud-q8-xl";
      slot_url = "http://127.0.0.1:8085";
      worker_count = 12;
      min_hot_slots = 10;
      required_final_markers = 12;
      max_turns = 12;
    }
  in
  let json = Agent_swarm_live_harness.manifest_json cfg in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "run id" "demo-run" (json |> member "run_id" |> to_string);
  Alcotest.(check string) "masc url" "http://127.0.0.1:9999"
    (json |> member "masc_url" |> to_string);
  Alcotest.(check string) "provider base url" "http://127.0.0.1:3034"
    (json |> member "provider_base_url" |> to_string);
  Alcotest.(check string) "model id" "qwen3.5-35b-a3b-ud-q8-xl"
    (json |> member "model_id" |> to_string);
  Alcotest.(check string) "slot url" "http://127.0.0.1:8085"
    (json |> member "slot_url" |> to_string);
  Alcotest.(check int) "min hot slots" 10
    (json |> member "min_hot_slots" |> to_int);
  Alcotest.(check int) "required final markers" 12
    (json |> member "required_final_markers" |> to_int);
  Alcotest.(check int) "worker count" 12
    (json |> member "expected_worker_count" |> to_int)

let test_worker_count_can_expand_deterministically () =
  let plans =
    Agent_swarm_live_harness.build_worker_plans ~worker_count:14 "hot-run"
  in
  Alcotest.(check int) "fourteen workers" 14 (List.length plans);
  let names =
    plans
    |> List.map (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name)
  in
  Alcotest.(check bool) "replica suffix present" true
    (List.exists (fun name -> String.ends_with ~suffix:"-r2" name) names)

let () =
  Alcotest.run "Agent_swarm_live_harness"
    [
      ( "manifest",
        [
          Alcotest.test_case "build worker plans is deterministic" `Quick
            test_build_worker_plans_is_deterministic;
          Alcotest.test_case "manifest respects provider override" `Quick
            test_manifest_respects_provider_override;
          Alcotest.test_case "worker count expands deterministically" `Quick
            test_worker_count_can_expand_deterministically;
        ] );
    ]
