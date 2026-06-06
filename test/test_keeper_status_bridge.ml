open Masc

let meta_with_summary summary =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "verifier");
          ("agent_name", `String "keeper-verifier-agent");
          ("trace_id", `String "trace-verifier");
          ("runtime_id", `String "ollama_cloud.deepseek-v4-flash");
        ])
  with
  | Ok meta -> { meta with continuity_summary = summary }
  | Error err -> Alcotest.fail ("meta_of_json_fixture failed: " ^ err)
;;

let blocker_of_summary summary =
  let config = Workspace.default_config "/tmp/masc-test-status-bridge" in
  Keeper_status_bridge.runtime_blocker_surface_opt config (meta_with_summary summary)
;;

let test_synthetic_idle_last_output_is_not_blocker () =
  let summary =
    "Decisions: [SYNTHETIC] Last output: No awaiting_verification tasks. \
     Board posts are 21-31 days old with no new signals. Pure idle turn."
  in
  Alcotest.(check (option string))
    "idle synthetic last output is not a blocker"
    None
    (Option.map (fun b -> b.Keeper_status_bridge.blocker_class) (blocker_of_summary summary))
;;

let test_synthetic_no_visible_output_remains_blocker () =
  let summary = "Decisions: [SYNTHETIC] No visible output this generation" in
  Alcotest.(check (option string))
    "no visible output remains synthetic_stall"
    (Some "synthetic_stall")
    (Option.map (fun b -> b.Keeper_status_bridge.blocker_class) (blocker_of_summary summary))
;;

let () =
  Alcotest.run
    "keeper_status_bridge"
    [
      ( "synthetic progress blockers",
        [
          Alcotest.test_case
            "idle synthetic last output is not blocker"
            `Quick
            test_synthetic_idle_last_output_is_not_blocker;
          Alcotest.test_case
            "no visible synthetic output remains blocker"
            `Quick
            test_synthetic_no_visible_output_remains_blocker;
        ] );
    ]
;;
