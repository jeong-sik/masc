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

let defaults_with_prompt_fields =
  { Keeper_types_profile.empty_keeper_profile_defaults with
    instructions = Some "profile instructions"
  ; mention_targets = [ "profile-target" ]
  }
;;

 let test_empty_live_meta_does_not_mask_profile_defaults_as_overrides () =
  init_runtime_default_for_tests ();
  let meta =
    { (make_meta ()) with
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
      instructions = "live instructions";
      mention_targets = [ "live-target" ];
    }
  in
  Alcotest.(check (list string))
    "non-empty live prompt fields still surface as overrides"
    [ "prompt.instructions"; "workspace.mention_targets" ]
    (Keeper_status_bridge.live_override_fields meta defaults_with_prompt_fields)
;;

(* SSOT: last_compaction_decision null-guard policy (issue #25323). Extracted to
   Keeper_meta_contract.compaction_decision_json_or_null and reused by
   keeper_status.ml / dashboard_http_keeper.ml. Pin the policy so the guard can't
   silently diverge across projection sites again. Counterfactual: dropping the
   [String.trim = ""] guard turns the empty/whitespace cases red. *)
let test_compaction_decision_empty_is_null () =
  let d = Keeper_meta_contract.compaction_runtime_decision_of_string "" in
  Alcotest.(check bool)
    "empty decision serializes to `Null"
    true
    (Keeper_meta_contract.compaction_decision_json_or_null d = `Null)
;;

let test_compaction_decision_whitespace_is_null () =
  let d = Keeper_meta_contract.compaction_runtime_decision_of_string "   " in
  Alcotest.(check bool)
    "whitespace-only decision serializes to `Null"
    true
    (Keeper_meta_contract.compaction_decision_json_or_null d = `Null)
;;

let test_compaction_decision_value_is_string () =
  let d =
    Keeper_meta_contract.compaction_runtime_decision_of_string "provider_overflow"
  in
  Alcotest.(check bool)
    "non-empty decision serializes to `String"
    true
    (Keeper_meta_contract.compaction_decision_json_or_null d
     = `String "provider_overflow")
;;

let () =
  Alcotest.run
    "keeper_status_bridge"
    [
      ( "last_compaction_decision null-guard SSOT",
        [
          Alcotest.test_case
            "empty decision -> `Null"
            `Quick
            test_compaction_decision_empty_is_null;
          Alcotest.test_case
            "whitespace decision -> `Null"
            `Quick
            test_compaction_decision_whitespace_is_null;
          Alcotest.test_case
            "value decision -> `String"
            `Quick
            test_compaction_decision_value_is_string;
        ] );
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
