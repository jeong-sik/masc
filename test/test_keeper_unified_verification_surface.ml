open Alcotest

module WO = Masc_mcp.Keeper_world_observation
module UM = Masc_mcp.Keeper_unified_metrics
module AE = Masc_mcp.Agent_economy

let base_observation : WO.world_observation =
  {
    pending_mentions = [];
    pending_board_events = [];
    pending_scope_messages = [];
    message_cursor_updates = [];
    idle_seconds = 0;
    active_goals = [];
    continuity_summary = "";
    worktree_change_summary = None;
    context_ratio = 0.0;
    economic_pressure = AE.Normal;
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    provider_capacity_blocked_task_count = 0;
    failed_task_count = 0;
    pending_verification_count = 0;
    backlog_updated_since_last_scheduled_autonomous = false;
    active_agent_count = 0;
    last_turn_budget = None;
    work_discovery_due = false;
  }

let sample_board_event : WO.pending_board_event =
  {
    post_id = "board-post-1";
    author = "alice";
    title = "Need help";
    preview = "Please take a look.";
    hearth = Some "research";
    post_kind = Masc_mcp.Board.Human_post;
    updated_at = 0.0;
    explicit_mention = false;
    matched_targets = [];
    self_commented = false;
    new_external_since = 0;
    latest_external_author = None;
    latest_external_preview = None;
  }

let make_meta name : Masc_mcp.Keeper_types.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("test-trace-" ^ name));
        ("goal", `String "test goal");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let minimal_meta : Masc_mcp.Keeper_types.keeper_meta = make_meta "test-keeper"

let test_task_verify_affordance_for_keeper () =
  let meta = { minimal_meta with mention_targets = [ "analyst" ] } in
  let obs = { base_observation with pending_verification_count = 3 } in
  let affordances = UM.observed_affordances_of_observation ~meta obs in
  check bool "task_verify present for keeper" true
    (List.mem "task_verify" affordances)

let test_task_verify_affordance_for_verifier_tag () =
  let meta = { minimal_meta with mention_targets = [ "verifier" ] } in
  let obs = { base_observation with pending_verification_count = 3 } in
  let affordances = UM.observed_affordances_of_observation ~meta obs in
  check bool "task_verify present for verifier-tagged keeper" true
    (List.mem "task_verify" affordances)

let test_task_verify_affordance_without_meta () =
  let obs = { base_observation with pending_verification_count = 2 } in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "task_verify present without meta" true
    (List.mem "task_verify" affordances)

let test_work_discovery_nudge_is_not_hard_contract () =
  let obs = { base_observation with work_discovery_due = true } in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "work_discovery present" true
    (List.mem "work_discovery" affordances);
  let contract_obs =
    Masc_mcp.Keeper_contract_classifier.of_keeper_world_observation obs
  in
  check bool "timer-only discovery is not actionable" false
    (Masc_mcp.Keeper_contract_classifier.is_actionable
       (Masc_mcp.Keeper_contract_classifier.classify_actionable_signal
          contract_obs))

let test_board_curation_affordance_requires_multi_event_window () =
  let second_board_event =
    {
      sample_board_event with
      post_id = "board-post-2";
      title = "Follow-up";
      preview = "Another board item needs routing.";
    }
  in
  let obs =
    {
      base_observation with
      pending_board_events = [ sample_board_event; second_board_event ];
    }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "board_curation present" true
    (List.mem "board_curation" affordances)

let test_single_board_event_skips_curation_gate () =
  let obs =
    { base_observation with pending_board_events = [ sample_board_event ] }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "board_curation absent" false
    (List.mem "board_curation" affordances)

let test_task_claim_requires_matched_backlog () =
  let obs =
    { base_observation with unclaimed_task_count = 3; claimable_task_count = 0 }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "task_claim absent for unclaimable backlog" false
    (List.mem "task_claim" affordances)

let test_task_claim_present_for_claimable_backlog () =
  let obs =
    { base_observation with unclaimed_task_count = 3; claimable_task_count = 1 }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "task_claim present for matched backlog" true
    (List.mem "task_claim" affordances)

let test_task_claim_suppressed_for_provider_blocked_backlog () =
  let obs =
    {
      base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 1;
      provider_capacity_blocked_task_count = 1;
    }
  in
  let affordances = UM.observed_affordances_of_observation obs in
  check bool "task_claim absent while provider capacity blocks work" false
    (List.mem "task_claim" affordances);
  check bool "provider capacity affordance present" true
    (List.mem "provider_capacity_blocked" affordances)

let test_janitor_discovery_sources_do_not_force_task_claim () =
  let meta =
    {
      minimal_meta with
      work_discovery_sources = Some [ "stale_tasks"; "board_cleanup" ];
    }
  in
  let obs =
    {
      base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 1;
      failed_task_count = 1;
      work_discovery_due = true;
    }
  in
  let affordances = UM.observed_affordances_of_observation ~meta obs in
  check bool "task_claim suppressed for janitor cleanup/audit sources" false
    (List.mem "task_claim" affordances);
  check bool "task_audit remains available for stale_tasks" true
    (List.mem "task_audit" affordances);
  check bool "board cleanup source maps to curation lane" true
    (List.mem "board_curation" affordances)

let test_unclaimed_discovery_source_keeps_task_claim () =
  let meta =
    { minimal_meta with work_discovery_sources = Some [ "unclaimed_tasks" ] }
  in
  let obs =
    {
      base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 1;
      work_discovery_due = true;
    }
  in
  let affordances = UM.observed_affordances_of_observation ~meta obs in
  check bool "task_claim present for unclaimed_tasks source" true
    (List.mem "task_claim" affordances)

let test_backlog_trigger_split () =
  let obs =
    { base_observation with unclaimed_task_count = 3; claimable_task_count = 1 }
  in
  let triggers = UM.observed_triggers_of_observation obs in
  check bool "absolute backlog trigger remains visible" true
    (List.mem "new_unclaimed_task" triggers);
  check bool "matched backlog trigger is explicit" true
    (List.mem "claimable_task" triggers)

let test_provider_capacity_blocked_trigger () =
  let obs =
    {
      base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 1;
      provider_capacity_blocked_task_count = 1;
    }
  in
  let triggers = UM.observed_triggers_of_observation obs in
  check bool "provider capacity trigger is explicit" true
    (List.mem "provider_capacity_blocked_backlog" triggers)

let test_pending_verification_trigger_for_keeper () =
  let meta = { minimal_meta with mention_targets = [ "scholar" ] } in
  let obs = { base_observation with pending_verification_count = 5 } in
  let triggers = UM.observed_triggers_of_observation ~meta obs in
  check bool "pending_verification present for keeper" true
    (List.mem "pending_verification" triggers)

let test_pending_verification_trigger_for_verifier_tag () =
  let meta = { minimal_meta with mention_targets = [ "검증자" ] } in
  let obs = { base_observation with pending_verification_count = 1 } in
  let triggers = UM.observed_triggers_of_observation ~meta obs in
  check bool "pending_verification present for verifier-tagged keeper" true
    (List.mem "pending_verification" triggers)

let () =
  run "keeper_unified_verification_surface"
    [
      ( "verification_surface",
        [
          test_case "affordance: keeper sees task_verify when pending>0" `Quick
            test_task_verify_affordance_for_keeper;
          test_case "affordance: verifier-tagged keeper also sees task_verify"
            `Quick test_task_verify_affordance_for_verifier_tag;
          test_case "affordance: no meta keeps legacy surface-to-all" `Quick
            test_task_verify_affordance_without_meta;
          test_case "affordance: work discovery nudge is not a hard contract"
            `Quick test_work_discovery_nudge_is_not_hard_contract;
          test_case "affordance: board curation requires multi-event window"
            `Quick test_board_curation_affordance_requires_multi_event_window;
          test_case "affordance: single board event skips curation gate" `Quick
            test_single_board_event_skips_curation_gate;
          test_case "affordance: task claim requires matched backlog" `Quick
            test_task_claim_requires_matched_backlog;
          test_case "affordance: task claim present for claimable backlog" `Quick
            test_task_claim_present_for_claimable_backlog;
          test_case
            "affordance: provider block suppresses task claim"
            `Quick test_task_claim_suppressed_for_provider_blocked_backlog;
          test_case
            "affordance: janitor discovery sources do not force task claim"
            `Quick test_janitor_discovery_sources_do_not_force_task_claim;
          test_case "affordance: unclaimed discovery source keeps task claim"
            `Quick test_unclaimed_discovery_source_keeps_task_claim;
          test_case "trigger: absolute and matched backlog split" `Quick
            test_backlog_trigger_split;
          test_case "trigger: provider capacity blocked backlog" `Quick
            test_provider_capacity_blocked_trigger;
          test_case "trigger: keeper sees pending_verification" `Quick
            test_pending_verification_trigger_for_keeper;
          test_case
            "trigger: verifier-tagged keeper also sees pending_verification"
            `Quick test_pending_verification_trigger_for_verifier_tag;
        ] );
    ]
