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

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}
;;

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "keeper_status_bridge_runtime_" ".toml" in
  write_file path runtime_toml;
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e
;;

let test_progress_narrative_is_not_runtime_blocker_source () =
  let summary =
    "Progress: waiting on sandbox egress for github.com push\n\
     Next: ask operator to approve the manual 4-gate unblock"
  in
  Alcotest.(check (option string))
    "progress text never creates runtime blocker class"
    None
    (Option.map (fun b -> b.Keeper_status_bridge.blocker_class) (blocker_of_summary summary))
;;

let test_synthetic_narrative_is_not_runtime_blocker_source () =
  let summary = "Decisions: [SYNTHETIC] No visible output this generation" in
  Alcotest.(check (option string))
    "synthetic text never creates runtime blocker class"
    None
    (Option.map (fun b -> b.Keeper_status_bridge.blocker_class) (blocker_of_summary summary))
;;

let defaults_with_prompt_fields =
  { Keeper_types_profile.empty_keeper_profile_defaults with
    manifest_path = Some "/tmp/keeper.toml";
    sandbox_profile = Some Keeper_types_profile_sandbox.Local;
    goal = Some "toml goal";
    short_goal = Some "toml short";
    mid_goal = Some "toml mid";
    long_goal = Some "toml long";
    instructions = Some "toml instructions";
    mention_targets = [ "toml-target" ];
  }
;;

let test_empty_live_meta_does_not_mask_profile_defaults_as_overrides () =
  init_runtime_default_for_tests ();
  let meta =
    { (meta_with_summary "") with
      goal = "";
      short_goal = "";
      mid_goal = "";
      long_goal = "";
      instructions = "";
      mention_targets = [];
    }
  in
  Alcotest.(check (list string))
    "empty live prompt fields inherit TOML defaults without override drift"
    []
    (Keeper_status_bridge.live_override_fields meta defaults_with_prompt_fields)
;;

let test_nonempty_live_meta_still_reports_profile_override () =
  init_runtime_default_for_tests ();
  let meta =
    { (meta_with_summary "") with
      goal = "live goal";
      instructions = "live instructions";
      mention_targets = [ "live-target" ];
    }
  in
  Alcotest.(check (list string))
    "non-empty live prompt fields still surface as overrides"
    [ "prompt.goal"; "prompt.instructions"; "workspace.mention_targets" ]
    (Keeper_status_bridge.live_override_fields meta defaults_with_prompt_fields)
;;

let () =
  Alcotest.run
    "keeper_status_bridge"
    [
      ( "progress narrative provenance",
        [
          Alcotest.test_case
            "progress narrative is not blocker source"
            `Quick
            test_progress_narrative_is_not_runtime_blocker_source;
          Alcotest.test_case
            "synthetic narrative is not blocker source"
            `Quick
            test_synthetic_narrative_is_not_runtime_blocker_source;
        ] );
      ( "profile default override provenance",
        [
          Alcotest.test_case
            "empty live self-model inherits TOML without drift"
            `Quick
            test_empty_live_meta_does_not_mask_profile_defaults_as_overrides;
          Alcotest.test_case
            "non-empty live self-model still reports override"
            `Quick
            test_nonempty_live_meta_still_reports_profile_override;
        ] );
    ]
;;
