open Alcotest
open Masc_mcp

module Coord = Masc_mcp.Coord
module KT = Masc_mcp.Keeper_types

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%d"
         prefix (Unix.getpid ()) !counter
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  Fs_compat.mkdir_p dir;
  dir

let with_store f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = tmpdir "keeper_feature_proof" in
  let config = Coord.default_config base_dir in
  ignore (Coord.init config ~agent_name:None);
  Keeper_tool_call_log.reset_for_testing ();
  Keeper_tool_call_log.init ~base_path:base_dir ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_call_log.reset_for_testing ();
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base_dir))))
    (fun () -> f config)

let make_meta ?(name = "alpha") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String (name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("cascade_name", `String Keeper_config.default_cascade_name);
          ("last_model_used", `String "openai:gpt-5.4");
          ("sandbox_profile", `String "local");
          ("network_mode", `String "none");
          ("goal", `String "Prove keeper feature coverage");
          ("short_goal", `String "Exercise feature gates");
          ("mid_goal", `String "Keep autonomy observable");
          ("long_goal", `String "Reach product-grade safe autonomy");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let persist_keeper
      config
      ?(proactive_enabled = true)
      ~name
      ~total_turns
      ~autonomous_action_count
      ~autonomous_tool_turn_count
      ~board_reactive_turn_count
      ~proactive_count_total
  =
  let base = make_meta ~name () in
  let now = Unix.gettimeofday () in
  let meta =
    {
      base with
      proactive = { enabled = proactive_enabled; idle_sec = 1; cooldown_sec = 1 };
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              total_turns;
              last_turn_ts = now;
              last_model_used = "openai:gpt-5.4";
            };
          proactive_rt =
            {
              base.runtime.proactive_rt with
              count_total = proactive_count_total;
              last_ts = (if proactive_count_total > 0 then now else 0.0);
              last_outcome =
                (if proactive_count_total > 0
                 then KT.Proactive_tool_use
                 else KT.Proactive_never_started);
            };
          autonomous_action_count;
          autonomous_turn_count = autonomous_action_count;
          autonomous_tool_turn_count;
          board_reactive_turn_count;
        };
    }
  in
  match KT.write_meta ~force:true config meta with
  | Ok () -> meta
  | Error err -> fail ("write_meta failed: " ^ err)

let log_tool
      ?(keeper_name = "alpha")
      ?sandbox_profile
      ?network_mode
      ?task_id
      ?goal_ids
      ?(success = true)
      tool_name
  =
  Keeper_tool_call_log.log_call
    ~keeper_name
    ~tool_name
    ~input:(`Assoc [])
    ~output_text:
      (if success then "ok" else {|{"ok":false,"error":"fixture_failure"}|})
    ~success
    ~duration_ms:1.0
    ?sandbox_profile
    ?network_mode
    ?task_id
    ?goal_ids
    ()

let docker_bash_output ?(success = true) () =
  if success then
    {|{"ok":true,"sandbox_profile":"docker","via":"docker","git_creds_enabled":true}|}
  else
    {|{"ok":false,"error":"fixture_failure","sandbox_profile":"docker","via":"docker","git_creds_enabled":true}|}

let log_docker_bash ?(keeper_name = "alpha") ?(success = true) command =
  Keeper_tool_call_log.log_call
    ~keeper_name
    ~tool_name:"keeper_bash"
    ~input:
      (`Assoc [
        ("cmd", `String command);
        ("git_creds_enabled", `Bool true);
      ])
    ~output_text:(docker_bash_output ~success ())
    ~success
    ~duration_ms:1.0
    ~sandbox_profile:"docker"
    ~network_mode:"inherit"
    ()

let write_decision_lines config keeper_name rows =
  let path = KT.keeper_decision_log_path config keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path
    (String.concat "\n" (List.map Yojson.Safe.to_string rows) ^ "\n")

let write_scheduled_decision config keeper_name =
  write_decision_lines config keeper_name
    [
      `Assoc [
        ("ts", `String "2026-05-06T01:00:00Z");
        ("channel", `String "scheduled_autonomous");
        ("outcome", `String "success");
      ];
    ]

let write_24h_turn_span config keeper_name ~now =
  write_decision_lines config keeper_name
    [
      `Assoc [
        ("ts_unix", `Float (now -. (25.0 *. 3600.0)));
        ( "ts",
          `String
            (Masc_domain.iso8601_of_unix_seconds
               (now -. (25.0 *. 3600.0))) );
        ("channel", `String "reactive");
        ("outcome", `String "success");
      ];
      `Assoc [
        ("ts_unix", `Float (now -. 60.0));
        ("ts", `String (Masc_domain.iso8601_of_unix_seconds (now -. 60.0)));
        ("channel", `String "scheduled_autonomous");
        ("outcome", `String "success");
      ];
    ]

let feature id json =
  Yojson.Safe.Util.(json |> member "features" |> to_list)
  |> List.find_opt (fun item ->
    Safe_ops.json_string_opt "id" item = Some id)
  |> Option.value
       ~default:
         (`Assoc [
           ("id", `String id);
           ("status", `String "missing");
         ])

let feature_status id json =
  feature id json
  |> Safe_ops.json_string_opt "status"
  |> Option.value ~default:"missing"

let feature_ids json =
  Yojson.Safe.Util.(json |> member "features" |> to_list)
  |> List.filter_map (Safe_ops.json_string_opt "id")

let required_tools id json =
  feature id json
  |> Yojson.Safe.Util.member "required_tools"
  |> Yojson.Safe.Util.to_list
  |> List.filter_map Yojson.Safe.Util.to_string_option

let weak_tool tool_name id json =
  feature id json
  |> Yojson.Safe.Util.member "weak_tools"
  |> Yojson.Safe.Util.to_list
  |> List.find_opt (fun item ->
    Safe_ops.json_string_opt "name" item = Some tool_name)

let keeper_evidence id json =
  feature id json |> Yojson.Safe.Util.member "keeper_evidence"

let json_string_values field json =
  Yojson.Safe.Util.(json |> member field |> to_list)
  |> List.filter_map Yojson.Safe.Util.to_string_option

let keeper_evidence_tool tool_name id json =
  keeper_evidence id json
  |> Yojson.Safe.Util.member "per_tool"
  |> Yojson.Safe.Util.to_list
  |> List.find_opt (fun item ->
    Safe_ops.json_string_opt "name" item = Some tool_name)

let keeper_evidence_stage stage_id json =
  keeper_evidence "docker_git_pr_workflow" json
  |> Yojson.Safe.Util.member "stages"
  |> Yojson.Safe.Util.to_list
  |> List.find_opt (fun item ->
    Safe_ops.json_string_opt "id" item = Some stage_id)

let scheduled_decision_log keeper_name json =
  keeper_evidence "scheduled_proactive_autonomy" json
  |> Yojson.Safe.Util.member "per_keeper"
  |> Yojson.Safe.Util.to_list
  |> List.find_opt (fun item ->
    Safe_ops.json_string_opt "keeper" item = Some keeper_name)
  |> Option.value
       ~default:
         (`Assoc [
           ("keeper", `String keeper_name);
           ("decision_log", `Assoc []);
         ])
  |> Yojson.Safe.Util.member "decision_log"

let test_json_reports_feature_gaps () =
  with_store @@ fun config ->
  ignore
    (persist_keeper config ~name:"alpha" ~total_turns:3
       ~autonomous_action_count:2 ~autonomous_tool_turn_count:2
       ~board_reactive_turn_count:1 ~proactive_count_total:1);
  ignore
    (persist_keeper config ~name:"beta" ~total_turns:2
       ~autonomous_action_count:1 ~autonomous_tool_turn_count:1
       ~board_reactive_turn_count:1 ~proactive_count_total:0);
  List.iter log_tool
    [
      "keeper_board_get";
      "keeper_board_list";
      "keeper_board_post";
      "keeper_board_comment";
      "keeper_board_vote";
      "masc_code_read";
    ];
  log_tool ~success:false ~sandbox_profile:"docker" ~network_mode:"inherit"
    ~task_id:"task-coding" ~goal_ids:["goal-coding"] "masc_worktree_create";
  let json =
    Dashboard_keeper_feature_proof.json
      ~config
      ~n:100
      ~success_threshold_pct:80.0
      ()
  in
  let summary = Yojson.Safe.Util.member "summary" json in
  check string "overall status has proof gaps" "fail"
    (Safe_ops.json_string ~default:"missing" "status" summary);
  check int "keeper_count" 2
    (Safe_ops.json_int ~default:0 "keeper_count" summary);
  check bool "gap_count is positive" true
    (Safe_ops.json_int ~default:0 "gap_count" summary > 0);
  check string "scheduled proactive gap is visible" "warn"
    (feature_status "scheduled_proactive_autonomy" json);
  check string "24h turn exchange requires decision log span" "fail"
    (feature_status "persistent_24h_turn_exchange" json);
  check string "board tools are fully proved" "pass"
    (feature_status "board_tools" json);
  check (list string) "board tool proof is keeper-originated"
    ["alpha"]
    (json_string_values "observed_keepers" (keeper_evidence "board_tools" json));
  check (list string) "board tool proof exposes missing keeper provenance"
    ["beta"]
    (json_string_values "missing_keepers" (keeper_evidence "board_tools" json));
  check string "coding tools are partial/weak proof" "warn"
    (feature_status "coding_tools" json);
  check bool "retired governance tools are not required" false
    (List.mem "governance_tools" (feature_ids json));
  check (list string) "approval proof follows current public surface"
    [ "masc_approval_pending" ]
    (required_tools "approval_tools" json);
  check (list string) "goal proof follows Goal FSM surface"
    [
      "masc_goal_list";
      "masc_goal_upsert";
      "masc_goal_transition";
      "masc_goal_verify";
      "masc_coordination_fsm_snapshot";
    ]
    (required_tools "goal_tools" json);
  let worktree_failure_classes =
    match weak_tool "masc_worktree_create" "coding_tools" json with
    | Some row ->
      Yojson.Safe.Util.(
        row |> member "failure_classes" |> to_list)
    | None -> []
  in
  check bool "weak tool includes failure class evidence" true
    (List.exists
       (fun row -> Safe_ops.json_string_opt "category" row = Some "fixture_failure")
       worktree_failure_classes);
  check bool "public failure classes omit raw samples" true
    (List.for_all
       (fun row -> Yojson.Safe.Util.member "sample" row = `Null)
       worktree_failure_classes);
  let worktree_evidence =
    match keeper_evidence_tool "masc_worktree_create" "coding_tools" json with
    | Some row -> row
    | None -> fail "missing worktree keeper evidence"
  in
  check (list string) "tool evidence records docker sandbox provenance"
    ["docker"]
    (json_string_values "sandbox_profiles" worktree_evidence);
  check (list string) "tool evidence records network provenance"
    ["inherit"]
    (json_string_values "network_modes" worktree_evidence);
  check (list string) "tool evidence records task provenance"
    ["task-coding"]
    (json_string_values "task_ids" worktree_evidence);
  check (list string) "tool evidence records goal provenance"
    ["goal-coding"]
    (json_string_values "goal_ids" worktree_evidence)

let test_operator_tool_calls_do_not_satisfy_keeper_tool_proof () =
  with_store @@ fun config ->
  ignore
    (persist_keeper config ~name:"alpha" ~total_turns:3
       ~autonomous_action_count:2 ~autonomous_tool_turn_count:2
       ~board_reactive_turn_count:1 ~proactive_count_total:1);
  List.iter
    (log_tool ~keeper_name:"operator")
    [
      "keeper_time_now";
      "keeper_context_status";
      "keeper_memory_search";
    ];
  let json =
    Dashboard_keeper_feature_proof.json
      ~config
      ~n:100
      ~success_threshold_pct:80.0
      ()
  in
  check string "non-keeper tool calls do not prove base tools" "fail"
    (feature_status "base_tools" json);
  let summary = Yojson.Safe.Util.member "summary" json in
  check int "operator calls excluded from keeper sample total" 0
    (Safe_ops.json_int ~default:(-1) "tool_sample_total" summary);
  check (float 0.001) "operator calls excluded from keeper success rate" 0.0
    (Safe_ops.json_float ~default:(-1.0) "tool_sample_success_rate" summary);
  check (list string) "base tools still missing from keeper proof"
    [
      "keeper_time_now";
      "keeper_context_status";
      "keeper_memory_search";
    ]
    (required_tools "base_tools" json
     |> List.filter (fun tool ->
       List.mem tool
         (feature "base_tools" json
          |> Yojson.Safe.Util.member "missing_tools"
          |> Yojson.Safe.Util.to_list
          |> List.filter_map Yojson.Safe.Util.to_string_option)));
  check (list string) "operator is not counted as observed keeper"
    []
    (json_string_values "observed_keepers" (keeper_evidence "base_tools" json));
  check (list string) "known keeper remains missing"
    ["alpha"]
    (json_string_values "missing_keepers" (keeper_evidence "base_tools" json))

let test_approval_latest_success_proves_recovery () =
  with_store @@ fun config ->
  ignore
    (persist_keeper config ~name:"alpha" ~total_turns:3
       ~autonomous_action_count:2 ~autonomous_tool_turn_count:2
       ~board_reactive_turn_count:1 ~proactive_count_total:1);
  for _ = 1 to 4 do
    log_tool ~success:false "masc_approval_pending"
  done;
  log_tool "masc_approval_pending";
  let json =
    Dashboard_keeper_feature_proof.json
      ~config
      ~n:100
      ~success_threshold_pct:80.0
      ()
  in
  check string "latest success after failure proves approval readback" "pass"
    (feature_status "approval_tools" json);
  let evidence =
    match keeper_evidence_tool "masc_approval_pending" "approval_tools" json with
    | Some row -> row
    | None -> fail "missing approval pending keeper evidence"
  in
  check (float 0.001) "success pct still records historical failures" 20.0
    (Safe_ops.json_float ~default:0.0 "success_pct" evidence);
  check bool "latest success timestamp exposed" true
    (Safe_ops.json_float_opt "latest_success_ts" evidence <> None);
  check bool "latest failure timestamp exposed" true
    (Safe_ops.json_float_opt "latest_failure_ts" evidence <> None)

let test_docker_git_pr_workflow_reports_partial_chain () =
  with_store @@ fun config ->
  ignore
    (persist_keeper config ~name:"alpha" ~total_turns:3
       ~autonomous_action_count:2 ~autonomous_tool_turn_count:2
       ~board_reactive_turn_count:1 ~proactive_count_total:1);
  log_docker_bash
    "git clone https://github.com/jeong-sik/masc-mcp.git /workspace/masc-mcp";
  log_docker_bash "git checkout -b fix/keeper-proof";
  log_docker_bash "git commit -m keeper-proof";
  log_docker_bash ~success:false "git push origin fix/keeper-proof";
  log_tool "keeper_pr_create";
  let json =
    Dashboard_keeper_feature_proof.json
      ~config
      ~n:100
      ~success_threshold_pct:80.0
      ()
  in
  check string "partial Docker git PR workflow is warn" "warn"
    (feature_status "docker_git_pr_workflow" json);
  let stage_passed id =
    match keeper_evidence_stage id json with
    | Some row -> Safe_ops.json_bool ~default:false "passed" row
    | None -> false
  in
  check bool "clone stage passes" true (stage_passed "docker_clone");
  check bool "branch stage passes" true (stage_passed "branch_create");
  check bool "commit stage passes" true (stage_passed "commit");
  check bool "push stage fails without success evidence" false
    (stage_passed "push");
  let push_failures =
    match keeper_evidence_stage "push" json with
    | Some row -> Safe_ops.json_int ~default:0 "failures" row
    | None -> 0
  in
  check int "push failure evidence is retained" 1 push_failures;
  check bool "PR creation remains missing" false (stage_passed "pr_create");
  check (list string) "workflow evidence is keeper-originated"
    ["alpha"]
    (json_string_values "observed_keepers"
       (keeper_evidence "docker_git_pr_workflow" json))

let test_decision_log_counts_as_scheduled_proof () =
  with_store @@ fun config ->
  let latest_success_ts = 1_777_001_500.0 in
  let older_success_ts = 1_777_001_000.0 in
  let newer_failure_ts = 1_777_002_000.0 in
  ignore
    (persist_keeper config ~name:"alpha" ~total_turns:3
       ~autonomous_action_count:2 ~autonomous_tool_turn_count:2
       ~board_reactive_turn_count:1 ~proactive_count_total:0);
  ignore
    (persist_keeper config ~name:"beta" ~total_turns:2
       ~autonomous_action_count:1 ~autonomous_tool_turn_count:1
       ~board_reactive_turn_count:1 ~proactive_count_total:0);
  write_decision_lines config "alpha"
    [
      `Assoc [
        ("ts_unix", `Float latest_success_ts);
        ("ts", `String (Masc_domain.iso8601_of_unix_seconds latest_success_ts));
        ("channel", `String "scheduled_autonomous");
        ("outcome", `String "success");
      ];
      `Assoc [
        ("ts_unix", `Float older_success_ts);
        ("ts", `String (Masc_domain.iso8601_of_unix_seconds older_success_ts));
        ("channel", `String "scheduled_autonomous");
        ("outcome", `String "success");
      ];
      `Assoc [
        ("ts_unix", `Float newer_failure_ts);
        ("ts", `String (Masc_domain.iso8601_of_unix_seconds newer_failure_ts));
        ("channel", `String "scheduled_autonomous");
        ("outcome", `String "failure");
      ];
    ];
  write_scheduled_decision config "beta";
  let json =
    Dashboard_keeper_feature_proof.json
      ~config
      ~n:100
      ~success_threshold_pct:80.0
      ()
  in
  let scheduled = feature "scheduled_proactive_autonomy" json in
  check string "decision log satisfies scheduled proof" "pass"
    (Safe_ops.json_string ~default:"missing" "status" scheduled);
  let observed =
    Yojson.Safe.Util.(
      scheduled
      |> member "keeper_evidence"
      |> member "observed_keepers"
      |> to_list)
  in
  check int "both keepers observed" 2 (List.length observed);
  let alpha_decision_log = scheduled_decision_log "alpha" json in
  check int "only successful scheduled decisions prove autonomy" 2
    (Safe_ops.json_int ~default:0 "decision_count" alpha_decision_log);
  check int "failed scheduled decisions stay visible" 1
    (Safe_ops.json_int ~default:0 "failure_count" alpha_decision_log);
  check (float 0.001) "latest scheduled proof uses max successful timestamp"
    latest_success_ts
    (Safe_ops.json_float ~default:0.0 "latest_ts_unix" alpha_decision_log)

let test_scheduled_proactive_evidence_uses_enabled_population () =
  with_store @@ fun config ->
  ignore
    (persist_keeper config ~name:"alpha" ~total_turns:3
       ~autonomous_action_count:2 ~autonomous_tool_turn_count:2
       ~board_reactive_turn_count:1 ~proactive_count_total:1);
  ignore
    (persist_keeper config ~proactive_enabled:false ~name:"beta" ~total_turns:2
       ~autonomous_action_count:1 ~autonomous_tool_turn_count:1
       ~board_reactive_turn_count:1 ~proactive_count_total:0);
  let json =
    Dashboard_keeper_feature_proof.json
      ~config
      ~n:100
      ~success_threshold_pct:80.0
      ()
  in
  let evidence = keeper_evidence "scheduled_proactive_autonomy" json in
  check int "scheduled evidence counts only enabled keepers" 1
    (Safe_ops.json_int ~default:0 "keeper_count" evidence);
  check int "scheduled meta count follows enabled keepers" 1
    (Safe_ops.json_int ~default:0 "meta_count" evidence);
  check (list string) "disabled keepers are not reported missing"
    []
    (json_string_values "missing_keepers" evidence);
  check (list string) "enabled keeper is observed"
    ["alpha"]
    (json_string_values "observed_keepers" evidence)

let test_persistent_24h_turn_exchange_counts_decision_span () =
  with_store @@ fun config ->
  let now = 1_777_000_000.0 in
  ignore
    (persist_keeper config ~name:"alpha" ~total_turns:5
       ~autonomous_action_count:2 ~autonomous_tool_turn_count:2
       ~board_reactive_turn_count:1 ~proactive_count_total:1);
  ignore
    (persist_keeper config ~name:"beta" ~total_turns:4
       ~autonomous_action_count:1 ~autonomous_tool_turn_count:1
       ~board_reactive_turn_count:1 ~proactive_count_total:1);
  write_24h_turn_span config "alpha" ~now;
  write_24h_turn_span config "beta" ~now;
  let json =
    Dashboard_keeper_feature_proof.json
      ~config
      ~n:100
      ~success_threshold_pct:80.0
      ~now
      ()
  in
  let persistent = feature "persistent_24h_turn_exchange" json in
  check string "24h decision span satisfies persistence proof" "pass"
    (Safe_ops.json_string ~default:"missing" "status" persistent);
  let observed =
    Yojson.Safe.Util.(
      persistent
      |> member "keeper_evidence"
      |> member "observed_keepers"
      |> to_list)
  in
  check int "both keepers have 24h span" 2 (List.length observed);
  let per_keeper =
    Yojson.Safe.Util.(
      persistent
      |> member "keeper_evidence"
      |> member "per_keeper"
      |> to_list)
  in
  check bool "per-keeper span evidence is exposed" true
    (List.for_all
       (fun row ->
          Safe_ops.json_float ~default:0.0 "span_hours" row >= 24.0
          && Safe_ops.json_bool ~default:false "meets_24h_persistence" row)
       per_keeper)

let () =
  run "dashboard_keeper_feature_proof"
    [
      ( "dashboard_keeper_feature_proof",
        [
          test_case "json reports feature gaps" `Quick
            test_json_reports_feature_gaps;
          test_case "operator calls do not prove keeper tool use" `Quick
            test_operator_tool_calls_do_not_satisfy_keeper_tool_proof;
          test_case "approval latest success proves recovery" `Quick
            test_approval_latest_success_proves_recovery;
          test_case "Docker git PR workflow reports partial chain" `Quick
            test_docker_git_pr_workflow_reports_partial_chain;
          test_case "decision log counts as scheduled proof" `Quick
            test_decision_log_counts_as_scheduled_proof;
          test_case "scheduled proof uses enabled population" `Quick
            test_scheduled_proactive_evidence_uses_enabled_population;
          test_case "decision log counts as 24h turn exchange proof" `Quick
            test_persistent_24h_turn_exchange_counts_decision_span;
        ] );
    ]
