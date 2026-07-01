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

let blocker_of_typed_last_blocker klass ~detail =
  let config = Workspace.default_config "/tmp/masc-test-status-bridge" in
  let meta = meta_with_summary "" in
  let meta =
    { meta with
      runtime =
        { meta.runtime with
          last_blocker =
            Some (Keeper_meta_contract.blocker_info_of_class ~detail klass)
        }
    }
  in
  Keeper_status_bridge.runtime_blocker_surface_opt config meta
;;

let runtime_blocker_facts_of_typed_last_blocker klass ~detail =
  let config = Workspace.default_config "/tmp/masc-test-status-bridge" in
  let meta = meta_with_summary "" in
  let meta =
    { meta with
      runtime =
        { meta.runtime with
          last_blocker =
            Some (Keeper_meta_contract.blocker_info_of_class ~detail klass)
        }
    }
  in
  match
    Keeper_status_bridge.runtime_blocker_fields_json config meta
    |> List.assoc_opt "runtime_blocker_facts"
  with
  | Some (`Assoc facts) -> facts
  | Some _ -> Alcotest.fail "expected runtime_blocker_facts object"
  | None -> Alcotest.fail "missing runtime_blocker_facts"
;;

let runtime_blocker_facts_of_no_progress_blocker ~detail ~reason ~streak ~threshold =
  let config = Workspace.default_config "/tmp/masc-test-status-bridge" in
  let meta = meta_with_summary "" in
  let meta =
    { meta with
      runtime =
        { meta.runtime with
          last_blocker =
            Some
              (Keeper_meta_contract.blocker_info_of_no_progress_loop
                 ~detail
                 ~reason
                 ~streak
                 ~threshold
                 ~latched:true
                 ())
        }
    }
  in
  match
    Keeper_status_bridge.runtime_blocker_fields_json config meta
    |> List.assoc_opt "runtime_blocker_facts"
  with
  | Some (`Assoc facts) -> facts
  | Some _ -> Alcotest.fail "expected runtime_blocker_facts object"
  | None -> Alcotest.fail "missing runtime_blocker_facts"
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

let test_no_progress_loop_summary_normalizes_legacy_detail () =
  let legacy_detail =
    "no_progress loop detected: streak=10 threshold=10; manual pause applied"
  in
  match
    blocker_of_typed_last_blocker Keeper_meta_contract.No_progress_loop
      ~detail:legacy_detail
  with
  | Some blocker ->
    Alcotest.(check string)
      "blocker class"
      "no_progress_loop"
      blocker.Keeper_status_bridge.blocker_class;
    Alcotest.(check bool)
      "normalizes legacy manual pause text"
      false
      (String_util.contains_substring_ci blocker.summary "manual pause");
    Alcotest.(check bool)
      "names progress safety latch"
      true
      (String_util.contains_substring_ci blocker.summary "progress-safety latch")
  | None -> Alcotest.fail "expected no_progress_loop blocker"
;;

let test_no_progress_runtime_blocker_facts_include_reason () =
  init_runtime_default_for_tests ();
  let detail =
    "operator-facing no-progress blocker text changed; no parseable tokens here"
  in
  let facts =
    runtime_blocker_facts_of_no_progress_blocker
      ~detail
      ~reason:"read_only"
      ~streak:10
      ~threshold:10
  in
  Alcotest.(check (option string))
    "reason comes from persisted blocker facts"
    (Some "read_only")
    (match List.assoc_opt "no_progress_reason" facts with
     | Some (`String value) -> Some value
     | _ -> None);
  Alcotest.(check (option string))
    "reason source names structured blocker facts"
    (Some "blocker_facts")
    (match List.assoc_opt "no_progress_reason_source" facts with
     | Some (`String value) -> Some value
     | _ -> None);
  Alcotest.(check (option int))
    "streak comes from persisted blocker facts"
    (Some 10)
    (match List.assoc_opt "no_progress_streak" facts with
     | Some (`Int value) -> Some value
     | _ -> None);
  Alcotest.(check (option int))
    "threshold comes from persisted blocker facts"
    (Some 10)
    (match List.assoc_opt "no_progress_threshold" facts with
     | Some (`Int value) -> Some value
     | _ -> None);
  Alcotest.(check (option bool))
    "typed no-progress blocker is latched"
    (Some true)
    (match List.assoc_opt "no_progress_latched" facts with
     | Some (`Bool value) -> Some value
     | _ -> None)
;;

(* Regression for the round-trip gap Copilot flagged on PR #22865:
   [Keeper_unified_turn_no_progress.mark_loop_detected] persists the literal
   string "unclassified" when no specific reason was classified, but
   [no_progress_reason_of_string] previously had no matching case for it, so
   the fact silently came back [None] even though the detail string carried a
   real (if unclassified) reason token. *)
let test_no_progress_runtime_blocker_facts_include_unclassified_reason () =
  init_runtime_default_for_tests ();
  let detail =
    "operator-facing no-progress blocker text changed; no parseable tokens here"
  in
  let facts =
    runtime_blocker_facts_of_no_progress_blocker
      ~detail
      ~reason:"unclassified"
      ~streak:10
      ~threshold:10
  in
  Alcotest.(check (option string))
    "unclassified reason round-trips from persisted blocker facts"
    (Some "unclassified")
    (match List.assoc_opt "no_progress_reason" facts with
     | Some (`String value) -> Some value
     | _ -> None)
;;

let test_no_progress_blocker_facts_round_trip_independent_of_detail () =
  init_runtime_default_for_tests ();
  let detail = "localized presentation sentence without key-value tokens" in
  let blocker =
    Keeper_meta_contract.blocker_info_of_no_progress_loop
      ~detail
      ~reason:"surface_mismatch"
      ~streak:12
      ~threshold:10
      ~latched:true
      ()
  in
  let meta =
    { (meta_with_summary "") with
      runtime =
        { (meta_with_summary "").runtime with
          last_blocker =
            Keeper_meta_contract.blocker_info_to_json blocker
            |> Keeper_meta_contract.blocker_info_of_json
        }
    }
  in
  let facts =
    match
      Keeper_status_bridge.runtime_blocker_fields_json
        (Workspace.default_config "/tmp/masc-test-status-bridge")
        meta
      |> List.assoc_opt "runtime_blocker_facts"
    with
    | Some (`Assoc facts) -> facts
    | Some _ -> Alcotest.fail "expected runtime_blocker_facts object"
    | None -> Alcotest.fail "missing runtime_blocker_facts"
  in
  Alcotest.(check (option string))
    "detail wording does not affect reason"
    (Some "surface_mismatch")
    (match List.assoc_opt "no_progress_reason" facts with
     | Some (`String value) -> Some value
     | _ -> None);
  Alcotest.(check (option int))
    "detail wording does not affect streak"
    (Some 12)
    (match List.assoc_opt "no_progress_streak" facts with
     | Some (`Int value) -> Some value
     | _ -> None);
  Alcotest.(check (option int))
    "detail wording does not affect threshold"
    (Some 10)
    (match List.assoc_opt "no_progress_threshold" facts with
     | Some (`Int value) -> Some value
     | _ -> None)
;;

let defaults_with_prompt_fields =
  { Keeper_types_profile.empty_keeper_profile_defaults with
    manifest_path = Some "/tmp/keeper.toml";
    sandbox_profile = Some Keeper_types_profile_sandbox.Local;
    goal = Some "toml goal";
    instructions = Some "toml instructions";
    mention_targets = [ "toml-target" ];
  }
;;

let test_empty_live_meta_does_not_mask_profile_defaults_as_overrides () =
  init_runtime_default_for_tests ();
  let meta =
    { (meta_with_summary "") with
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
          Alcotest.test_case
            "no-progress loop summary normalizes legacy detail"
            `Quick
            test_no_progress_loop_summary_normalizes_legacy_detail;
          Alcotest.test_case
            "no-progress blocker facts include typed reason"
            `Quick
            test_no_progress_runtime_blocker_facts_include_reason;
          Alcotest.test_case
            "no-progress blocker facts include unclassified reason"
            `Quick
            test_no_progress_runtime_blocker_facts_include_unclassified_reason;
          Alcotest.test_case
            "no-progress blocker facts survive detail wording changes"
            `Quick
            test_no_progress_blocker_facts_round_trip_independent_of_detail;
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
