open Masc

let make_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "verifier");
          ("agent_name", `String "keeper-verifier-agent");
          ("trace_id", `String "trace-verifier");
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

let test_age_seconds_preserves_missing_timestamp () =
  Alcotest.check (Alcotest.option (Alcotest.float 0.0001))
    "zero sentinel becomes missing age"
    None
    (Keeper_status_metrics.age_seconds_opt ~now_ts:100.0 0.0);
  Alcotest.check (Alcotest.option (Alcotest.float 0.0001))
    "negative sentinel becomes missing age"
    None
    (Keeper_status_metrics.age_seconds_opt ~now_ts:100.0 (-1.0));
  Alcotest.check (Alcotest.option (Alcotest.float 0.0001))
    "real timestamp remains an age"
    (Some 25.0)
    (Keeper_status_metrics.age_seconds_opt ~now_ts:100.0 75.0)
;;

let test_tool_audit_cache_advances_from_negative_by_appended_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  let base_path =
    Filename.temp_dir "keeper_status_tool_audit_cache_" ""
  in
  Fun.protect
    ~finally:(fun () ->
      Eio_guard.disable ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      let keeper_name = "tool-audit-cache" in
      let store =
        Keeper_types_support.keeper_metrics_store config keeper_name
      in
      let heartbeat sequence =
        `Assoc
          (Keeper_metrics_record.fields Keeper_metrics_record.Heartbeat
           @ [ "ts", `String "2026-07-30T05:00:00Z"
             ; "ts_unix", `Float 1_785_388_400.0
             ; "channel", `String "heartbeat"
             ; "sequence", `Int sequence
             ])
      in
      Dated_jsonl.append store (heartbeat 1);
      Alcotest.(check bool)
        "initial current-schema negative lookup"
        true
        (Option.is_none
           (Keeper_status_metrics.latest_tool_audit_snapshot_from_files
              config
              ~keeper_name));
      Dated_jsonl.append store (heartbeat 2);
      Alcotest.(check bool)
        "appended heartbeat preserves cached negative result"
        true
        (Option.is_none
           (Keeper_status_metrics.latest_tool_audit_snapshot_from_files
              config
              ~keeper_name));
      Dated_jsonl.append store
        (`Assoc
          (Keeper_metrics_record.fields Keeper_metrics_record.Turn
           @ [ "ts", `String "2026-07-30T05:00:01Z"
             ; "ts_unix", `Float 1_785_388_401.0
             ; "trace_id", `String "trace-tool-audit-cache"
             ; "generation", `Int 0
             ; "channel", `String "turn"
             ; "turn_mode", `String "tool_use"
             ; "latency_ms", `Int 1
             ; "handoff_performed", `Bool false
             ; "tool_call_count", `Int 1
             ; "tools_used", `List [ `String "masc_status" ]
             ]));
      match
        Keeper_status_metrics.latest_tool_audit_snapshot_from_files
          config
          ~keeper_name
      with
      | Some snapshot ->
          Alcotest.(check (list string))
            "new turn advances the incremental audit snapshot"
            [ "masc_status" ]
            snapshot.latest_tool_names
      | None -> Alcotest.fail "expected appended current-schema turn audit")
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
      ( "timestamp age sentinel SSOT",
        [ Alcotest.test_case
            "missing timestamps do not become zero age"
            `Quick
            test_age_seconds_preserves_missing_timestamp
        ] );
      ( "tool audit cache",
        [ Alcotest.test_case
            "negative snapshot advances from appended rows"
            `Quick
            test_tool_audit_cache_advances_from_negative_by_appended_rows
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
