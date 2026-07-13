open Masc

let make_meta () =
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
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json_fixture failed: " ^ err)
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

 let test_empty_live_meta_does_not_mask_profile_defaults_as_overrides () =
  init_runtime_default_for_tests ();
  let meta =
    { (make_meta ()) with
      goal = "";
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
    { (make_meta ()) with
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
      ( "profile default override provenance",
        [
          Alcotest.test_case
            "empty live identity inherits TOML without drift"
            `Quick
            test_empty_live_meta_does_not_mask_profile_defaults_as_overrides;
          Alcotest.test_case
            "non-empty live identity still reports override"
            `Quick
            test_nonempty_live_meta_still_reports_profile_override;
        ] );
    ]
;;
