open Alcotest

module Team_session_types = Team_session_types

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

let replace_assoc_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | json -> json

let remove_assoc_field key = function
  | `Assoc fields -> `Assoc (List.remove_assoc key fields)
  | json -> json

let sample_planned_worker =
  let open Team_session_types in
  {
    spawn_agent = "worker";
    runtime_actor = Some "worker-a";
    spawn_role = Some "executor";
    spawn_model = Some "glm-5";
    execution_scope = Some Observe_only;
    thinking_enabled = None;
    thinking_budget = None;
    max_turns = None;
    timeout_seconds = None;
    worker_class = Some Worker_executor;
    parent_actor = Some "fixture-root";
    capsule_mode = Some Capsule_inherit;
    runtime_pool = Some "default";
    lane_id = Some "lane-a";
    controller_level = Some Controller_worker;
    control_domain = Some Domain_execution;
    supervisor_actor = Some "fixture-root";
    task_profile = Some Profile_verify;
    risk_level = Some Risk_medium;
    routing_confidence = Some 0.72;
    routing_reason = Some "validate parser";
    routing_escalated = false;
  }

let sample_session () =
  let open Team_session_types in
  {
    session_id = "ts-parse-1";
    goal = "Tighten persisted session parsing";
    created_by = "fixture-root";
    origin_kind = Origin_human;
    room_id = "default";
    operation_id = Some "op-parse-1";
    status = Running;
    duration_seconds = 1800;
    execution_scope = Observe_only;
    checkpoint_interval_sec = 60;
    min_agents = 2;
    scale_profile = Scale_standard;
    control_profile = Control_flat;
    orchestration_mode = Assist;
    communication_mode = Comm_broadcast;
    model_cascade = [ "glm-5"; "gpt-5.4" ];
    fallback_policy = Fallback_cascade_then_task;
    instruction_profile = Profile_strict;
    alert_channel = Alert_both;
    auto_resume = true;
    report_formats = [ Markdown; Json ];
    turn_count = 3;
    agent_names = [ "fixture-root"; "worker-a" ];
    planned_workers = [ sample_planned_worker ];
    broadcast_count = 1;
    portal_count = 0;
    cascade_attempted = 1;
    cascade_success = 1;
    cascade_failed = 0;
    fallback_task_created = 0;
    min_agents_violation_streak = 0;
    policy_violations = [];
    baseline_done_counts = [ ("worker-a", 1) ];
    final_done_delta_total = Some 2;
    final_done_delta_by_agent = Some [ ("worker-a", 2) ];
    started_at = 1000.0;
    planned_end_at = 2800.0;
    stopped_at = None;
    last_checkpoint_at = Some 1100.0;
    last_event_at = Some 1200.0;
    last_turn_at = Some 1250.0;
    stop_reason = None;
    generated_report = false;
    delivery_contract =
      Some
        {
          contract_id = "contract-1";
          summary = "deliver mission report";
          acceptance_checks = [ "all tests green" ];
          required_artifacts = [ "report.md" ];
          repair_budget = 1;
          generator_roles = [ "executor" ];
          evaluator_role = Some "verifier";
          evaluator_cascade = "cross_verifier";
          evidence_refs = [ "ev-1" ];
          updated_by = "fixture-root";
          updated_at_iso = "2026-04-10T00:00:00Z";
        };
    latest_delivery_verdict =
      Some
        {
          contract_id = "contract-1";
          status = Delivery_pass;
          summary = "looks good";
          evaluator = "verifier";
          evaluator_role = Some "verifier";
          evaluator_cascade = "cross_verifier";
          repair_directive = None;
          evidence_refs = [ "ev-1" ];
          generated_at_iso = "2026-04-10T00:10:00Z";
        };
    artifacts_dir = "/tmp/artifacts";
    created_at_iso = "2026-04-10T00:00:00Z";
    updated_at_iso = "2026-04-10T00:10:00Z";
  }

let sample_checkpoint () =
  let open Team_session_types in
  {
    ts = 1200.0;
    ts_iso = "2026-04-10T00:20:00Z";
    status = Running;
    elapsed_sec = 200;
    remaining_sec = 1600;
    progress_pct = 12.5;
    done_delta_total = 2;
    done_delta_by_agent = [ ("worker-a", 2) ];
    active_agents = [ "fixture-root"; "worker-a" ];
  }

let test_session_result_roundtrip () =
  let json =
    Team_session_types.session_to_yojson (sample_session ())
  in
  match Team_session_types.session_of_yojson_result json with
  | Ok parsed ->
      check string "session_id" "ts-parse-1" parsed.session_id;
      check string "status" "running"
        (Team_session_types.status_to_string parsed.status);
      check int "planned worker count" 1 (List.length parsed.planned_workers);
      check (option string) "operation_id" (Some "op-parse-1")
        parsed.operation_id
  | Error message -> fail message

let test_session_result_rejects_missing_required_field () =
  let json =
    Team_session_types.session_to_yojson (sample_session ())
    |> remove_assoc_field "status"
  in
  match Team_session_types.session_of_yojson_result json with
  | Ok _ -> fail "expected parser to reject missing status"
  | Error message ->
      check bool "mentions status" true
        (contains_substring message "status")

let test_session_result_rejects_unknown_execution_scope () =
  let json =
    Team_session_types.session_to_yojson (sample_session ())
    |> replace_assoc_field "execution_scope" (`String "bogus_scope")
  in
  match Team_session_types.session_of_yojson_result json with
  | Ok _ -> fail "expected parser to reject unknown execution scope"
  | Error message ->
      check bool "mentions execution_scope" true
        (contains_substring message "execution_scope")

let test_session_result_rejects_invalid_planned_worker_enum () =
  let bad_worker =
    Team_session_types.planned_worker_to_yojson sample_planned_worker
    |> replace_assoc_field "worker_class" (`String "bogus_worker_class")
  in
  let json =
    Team_session_types.session_to_yojson (sample_session ())
    |> replace_assoc_field "planned_workers" (`List [ bad_worker ])
  in
  match Team_session_types.session_of_yojson_result json with
  | Ok _ -> fail "expected parser to reject invalid worker_class"
  | Error message ->
      check bool "mentions worker_class" true
        (contains_substring message "worker_class")

let test_session_result_rejects_invalid_planned_worker_bool_type () =
  let bad_worker =
    Team_session_types.planned_worker_to_yojson sample_planned_worker
    |> replace_assoc_field "thinking_enabled" (`String "yes")
  in
  let json =
    Team_session_types.session_to_yojson (sample_session ())
    |> replace_assoc_field "planned_workers" (`List [ bad_worker ])
  in
  match Team_session_types.session_of_yojson_result json with
  | Ok _ -> fail "expected parser to reject invalid thinking_enabled type"
  | Error message ->
      check bool "mentions thinking_enabled" true
        (contains_substring message "thinking_enabled")

let test_session_result_rejects_empty_report_formats () =
  let json =
    Team_session_types.session_to_yojson (sample_session ())
    |> replace_assoc_field "report_formats" (`List [])
  in
  match Team_session_types.session_of_yojson_result json with
  | Ok _ -> fail "expected parser to reject empty report_formats"
  | Error message ->
      check bool "mentions report_formats" true
        (contains_substring message "report_formats")

let test_session_result_rejects_invalid_nested_delivery_verdict () =
  let bad_verdict =
    match Team_session_types.session_to_yojson (sample_session ()) with
    | `Assoc fields -> (
        match List.assoc_opt "latest_delivery_verdict" fields with
        | Some (`Assoc _ as verdict) ->
            replace_assoc_field "status" (`String "mystery") verdict
        | _ -> failwith "sample session missing verdict")
    | _ -> failwith "sample session should serialize as object"
  in
  let json =
    Team_session_types.session_to_yojson (sample_session ())
    |> replace_assoc_field "latest_delivery_verdict" bad_verdict
  in
  match Team_session_types.session_of_yojson_result json with
  | Ok _ -> fail "expected parser to reject invalid nested delivery verdict"
  | Error message ->
      check bool "mentions latest_delivery_verdict" true
        (contains_substring message "latest_delivery_verdict")

let test_session_result_rejects_negative_delivery_contract_repair_budget () =
  let bad_contract =
    match Team_session_types.session_to_yojson (sample_session ()) with
    | `Assoc fields -> (
        match List.assoc_opt "delivery_contract" fields with
        | Some (`Assoc _ as contract) ->
            replace_assoc_field "repair_budget" (`Int (-1)) contract
        | _ -> failwith "sample session missing contract")
    | _ -> failwith "sample session should serialize as object"
  in
  let json =
    Team_session_types.session_to_yojson (sample_session ())
    |> replace_assoc_field "delivery_contract" bad_contract
  in
  match Team_session_types.session_of_yojson_result json with
  | Ok _ -> fail "expected parser to reject negative repair_budget"
  | Error message ->
      check bool "mentions repair_budget" true
        (contains_substring message "repair_budget")

let test_session_wrapper_returns_none_on_invalid_json () =
  let json =
    Team_session_types.session_to_yojson (sample_session ())
    |> remove_assoc_field "status"
  in
  check bool "wrapper returns none" true
    (Option.is_none (Team_session_types.session_of_yojson json))

let test_checkpoint_result_rejects_unknown_status () =
  let json =
    Team_session_types.checkpoint_to_yojson (sample_checkpoint ())
    |> replace_assoc_field "status" (`String "mystery")
  in
  match Team_session_types.checkpoint_of_yojson json with
  | Ok _ -> fail "expected checkpoint parser to reject unknown status"
  | Error message ->
      check bool "mentions status" true
        (contains_substring message "status")

let () =
  run "team_session_types_parsing"
    [
      ( "session",
        [
          test_case "roundtrip" `Quick test_session_result_roundtrip;
          test_case "rejects missing status" `Quick
            test_session_result_rejects_missing_required_field;
          test_case "rejects unknown execution_scope" `Quick
            test_session_result_rejects_unknown_execution_scope;
          test_case "rejects invalid planned worker enum" `Quick
            test_session_result_rejects_invalid_planned_worker_enum;
          test_case "rejects invalid planned worker bool type" `Quick
            test_session_result_rejects_invalid_planned_worker_bool_type;
          test_case "rejects empty report_formats" `Quick
            test_session_result_rejects_empty_report_formats;
          test_case "rejects invalid nested delivery verdict" `Quick
            test_session_result_rejects_invalid_nested_delivery_verdict;
          test_case "rejects negative contract repair_budget" `Quick
            test_session_result_rejects_negative_delivery_contract_repair_budget;
          test_case "wrapper returns none on invalid payload" `Quick
            test_session_wrapper_returns_none_on_invalid_json;
        ] );
      ( "checkpoint",
        [
          test_case "rejects unknown status" `Quick
            test_checkpoint_result_rejects_unknown_status;
        ] );
    ]
