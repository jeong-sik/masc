open Alcotest

module D = Masc_mcp.Keeper_deliberation
module Contract = Masc_mcp.Keeper_contract
module Keeper_types = Masc_mcp.Keeper_types

(* ---------- Triage tests ---------- *)

let base_obs =
  D.empty_world_observation ~keeper_name:"test-keeper"

let test_triage_skip_on_empty_observation () =
  let result = D.triage base_obs in
  match result with
  | D.Skip _ -> ()
  | D.Triggered _ ->
      fail "expected Skip for empty observation, got Triggered"

let test_triage_direct_mention () =
  let obs = { base_obs with direct_mention = true } in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for direct mention"
  | D.Triggered triggers ->
      check bool "contains DirectMention" true
        (List.mem D.DirectMention triggers)

let test_triage_unclaimed_task () =
  let obs = { base_obs with unclaimed_task_count = 3 } in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for unclaimed tasks"
  | D.Triggered triggers ->
      check bool "contains NewUnclaimedTask" true
        (List.mem D.NewUnclaimedTask triggers)

let test_triage_failed_task () =
  let obs = { base_obs with failed_task_count = 1 } in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for failed task"
  | D.Triggered triggers ->
      check bool "contains FailedTask" true
        (List.mem D.FailedTask triggers)

let test_triage_agent_change () =
  let obs = { base_obs with agent_count_changed = true } in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for agent change"
  | D.Triggered triggers ->
      check bool "contains AgentJoinedOrLeft" true
        (List.mem D.AgentJoinedOrLeft triggers)

let test_triage_board_mention () =
  let obs = { base_obs with board_mention_count = 2 } in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for board mention"
  | D.Triggered triggers ->
      let has_board_activity =
        List.exists
          (function D.BoardActivity _ -> true | _ -> false)
          triggers
      in
      check bool "contains BoardActivity" true has_board_activity

let test_triage_idle_with_goals () =
  let obs =
    { base_obs with idle_seconds = 600; idle_gate = 300; active_goal_count = 2 }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for idle timeout with goals"
  | D.Triggered triggers ->
      check bool "contains IdleTimeout" true
        (List.mem D.IdleTimeout triggers)

let test_triage_idle_without_goals_skips () =
  let obs =
    { base_obs with idle_seconds = 600; idle_gate = 300; active_goal_count = 0 }
  in
  match D.triage obs with
  | D.Skip _ -> ()
  | D.Triggered _ ->
      fail "idle without goals should not trigger"

let test_triage_multiple_triggers () =
  let obs =
    { base_obs with
      direct_mention = true;
      unclaimed_task_count = 1;
      failed_task_count = 1;
    }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected multiple triggers"
  | D.Triggered triggers ->
      check bool "at least 3 triggers" true (List.length triggers >= 3)

(* ---------- Action type tests ---------- *)

let test_action_to_legacy_string_noop () =
  check string "noop legacy" "noop"
    (D.deliberation_action_to_legacy_string (D.Noop "test"))

let test_action_to_legacy_string_reply () =
  check string "reply legacy" "reply_in_room"
    (D.deliberation_action_to_legacy_string
       (D.ReplyInRoom { room_id = "r1"; content = "hello" }))

let test_action_to_legacy_string_board_post () =
  check string "board_post legacy" "board_post"
    (D.deliberation_action_to_legacy_string
       (D.BoardPost { content = "test"; hearth = None }))

let test_action_to_legacy_string_task_claim () =
  check string "task_claim legacy" "task_claim"
    (D.deliberation_action_to_legacy_string
       (D.TaskClaim { task_id = "t-1"; reason = "needed" }))

let test_action_to_json_roundtrip () =
  let action = D.ReplyInRoom { room_id = "room-1"; content = "hello" } in
  let json = D.deliberation_action_to_json action in
  let typ =
    Yojson.Safe.Util.member "type" json |> Yojson.Safe.Util.to_string
  in
  check string "json type field" "reply_in_room" typ

let test_action_to_json_noop () =
  let action = D.Noop "nothing to do" in
  let json = D.deliberation_action_to_json action in
  let reason =
    Yojson.Safe.Util.member "reason" json |> Yojson.Safe.Util.to_string
  in
  check string "noop reason preserved" "nothing to do" reason

let test_action_multistep_to_string () =
  let action =
    D.MultiStep
      [
        D.TaskClaim { task_id = "t-1"; reason = "urgent" };
        D.Broadcast { message = "claimed t-1" };
      ]
  in
  let s = D.deliberation_action_to_string action in
  check bool "starts with multi_step" true
    (String.length s > 10 && String.sub s 0 10 = "multi_step")

(* ---------- Baseline action tests ---------- *)

let test_baseline_mention_returns_reply () =
  let obs = { base_obs with direct_mention = true } in
  let action = D.deterministic_baseline_action obs in
  match action with
  | D.ReplyInRoom _ -> ()
  | _ -> fail "expected ReplyInRoom for direct mention"

let test_baseline_no_mention_returns_noop () =
  let obs = base_obs in
  let action = D.deterministic_baseline_action obs in
  match action with
  | D.Noop _ -> ()
  | _ -> fail "expected Noop for no mention"

(* ---------- Deliberation meta tests ---------- *)

let test_deliberation_meta_json_roundtrip () =
  let dm =
    { D.deliberation_count = 42;
      deliberation_cost_total_usd = 0.05;
      last_deliberation_ts = 1710000000.0;
      last_triage_triggers = "direct_mention,new_unclaimed_task";
    }
  in
  let pairs = D.deliberation_meta_to_json dm in
  let json = `Assoc pairs in
  let dm2 = D.deliberation_meta_of_json json in
  check int "count roundtrip" 42 dm2.deliberation_count;
  check (float 0.001) "cost roundtrip" 0.05 dm2.deliberation_cost_total_usd;
  check (float 0.1) "ts roundtrip" 1710000000.0 dm2.last_deliberation_ts;
  check string "triggers roundtrip" "direct_mention,new_unclaimed_task"
    dm2.last_triage_triggers

let test_deliberation_meta_defaults () =
  let dm = D.deliberation_meta_of_json (`Assoc []) in
  check int "default count" 0 dm.deliberation_count;
  check (float 0.001) "default cost" 0.0 dm.deliberation_cost_total_usd;
  check (float 0.001) "default ts" 0.0 dm.last_deliberation_ts;
  check string "default triggers" "" dm.last_triage_triggers

(* ---------- Policy mode tests ---------- *)

let test_policy_mode_llm_deliberation_parse () =
  match Contract.parse_policy_mode "llm_deliberation" with
  | Some Contract.Llm_deliberation -> ()
  | _ -> fail "expected Llm_deliberation"

let test_policy_mode_llm_deliberation_roundtrip () =
  let s = Contract.policy_mode_to_string Contract.Llm_deliberation in
  check string "to_string" "llm_deliberation" s;
  match Contract.policy_mode_of_string s with
  | Contract.Llm_deliberation -> ()
  | _ -> fail "expected roundtrip to Llm_deliberation"

let test_policy_mode_is_deliberation () =
  check bool "llm_deliberation is deliberation" true
    (Contract.policy_mode_is_deliberation Contract.Llm_deliberation);
  check bool "heuristic is not deliberation" false
    (Contract.policy_mode_is_deliberation Contract.Heuristic);
  check bool "learned is not deliberation" false
    (Contract.policy_mode_is_deliberation Contract.Learned_offline_v1)

(* ---------- Keeper meta deliberation fields ---------- *)

let test_keeper_meta_deliberation_fields_roundtrip () =
  let json =
    `Assoc
      [
        ("name", `String "test-keeper");
        ("trace_id", `String "trace-1");
        ("goal", `String "test deliberation");
        ("models", `List [ `String "custom:test-model" ]);
        ("policy_mode", `String "llm_deliberation");
        ("deliberation_count", `Int 5);
        ("deliberation_cost_total_usd", `Float 0.03);
        ("last_deliberation_ts", `Float 1710000000.0);
        ("last_triage_triggers", `String "direct_mention");
      ]
  in
  match Keeper_types.meta_of_json json with
  | Error err -> fail ("meta parse failed: " ^ err)
  | Ok meta ->
      check string "policy mode" "llm_deliberation" meta.policy_mode;
      check int "deliberation count" 5 meta.deliberation_count;
      check (float 0.001) "deliberation cost" 0.03
        meta.deliberation_cost_total_usd;
      check (float 0.1) "deliberation ts" 1710000000.0
        meta.last_deliberation_ts;
      check string "triage triggers" "direct_mention"
        meta.last_triage_triggers

let test_keeper_meta_deliberation_fields_default () =
  let json =
    `Assoc
      [
        ("name", `String "test-keeper-2");
        ("trace_id", `String "trace-2");
        ("goal", `String "test defaults");
        ("models", `List [ `String "custom:test-model" ]);
      ]
  in
  match Keeper_types.meta_of_json json with
  | Error err -> fail ("meta parse failed: " ^ err)
  | Ok meta ->
      check int "default deliberation count" 0 meta.deliberation_count;
      check (float 0.001) "default deliberation cost" 0.0
        meta.deliberation_cost_total_usd;
      check (float 0.001) "default deliberation ts" 0.0
        meta.last_deliberation_ts;
      check string "default triage triggers" ""
        meta.last_triage_triggers

(* ---------- Triage result JSON ---------- *)

let test_triage_result_skip_json () =
  let json = D.triage_result_to_json (D.Skip "quiet room") in
  let decision =
    Yojson.Safe.Util.member "decision" json |> Yojson.Safe.Util.to_string
  in
  check string "skip decision" "skip" decision

let test_triage_result_triggered_json () =
  let json =
    D.triage_result_to_json
      (D.Triggered [ D.DirectMention; D.NewUnclaimedTask ])
  in
  let decision =
    Yojson.Safe.Util.member "decision" json |> Yojson.Safe.Util.to_string
  in
  let triggers =
    Yojson.Safe.Util.member "triggers" json |> Yojson.Safe.Util.to_list
  in
  check string "triggered decision" "triggered" decision;
  check int "trigger count" 2 (List.length triggers)

(* ---------- World observation JSON ---------- *)

let test_world_observation_json () =
  let obs = { base_obs with direct_mention = true; unclaimed_task_count = 3 } in
  let json = D.world_observation_to_json obs in
  let dm =
    Yojson.Safe.Util.member "direct_mention" json |> Yojson.Safe.Util.to_bool
  in
  let utc =
    Yojson.Safe.Util.member "unclaimed_task_count" json
    |> Yojson.Safe.Util.to_int
  in
  check bool "direct_mention in json" true dm;
  check int "unclaimed_task_count in json" 3 utc

(* ---------- Canonical policy mode ---------- *)

let test_canonical_policy_mode_llm_deliberation () =
  check string "canonical llm_deliberation" "llm_deliberation"
    (Keeper_types.canonical_policy_mode "llm_deliberation")

let test_canonical_policy_mode_heuristic () =
  check string "canonical heuristic" "heuristic"
    (Keeper_types.canonical_policy_mode "heuristic")

let test_canonical_policy_mode_unknown () =
  check string "canonical unknown" "heuristic"
    (Keeper_types.canonical_policy_mode "unknown_mode")

let () =
  run "Keeper_deliberation"
    [
      ( "triage",
        [
          test_case "skip on empty observation" `Quick
            test_triage_skip_on_empty_observation;
          test_case "direct mention triggers" `Quick
            test_triage_direct_mention;
          test_case "unclaimed task triggers" `Quick
            test_triage_unclaimed_task;
          test_case "failed task triggers" `Quick
            test_triage_failed_task;
          test_case "agent change triggers" `Quick
            test_triage_agent_change;
          test_case "board mention triggers" `Quick
            test_triage_board_mention;
          test_case "idle with goals triggers" `Quick
            test_triage_idle_with_goals;
          test_case "idle without goals skips" `Quick
            test_triage_idle_without_goals_skips;
          test_case "multiple triggers" `Quick
            test_triage_multiple_triggers;
        ] );
      ( "actions",
        [
          test_case "noop to legacy string" `Quick
            test_action_to_legacy_string_noop;
          test_case "reply to legacy string" `Quick
            test_action_to_legacy_string_reply;
          test_case "board_post to legacy string" `Quick
            test_action_to_legacy_string_board_post;
          test_case "task_claim to legacy string" `Quick
            test_action_to_legacy_string_task_claim;
          test_case "action to json roundtrip" `Quick
            test_action_to_json_roundtrip;
          test_case "noop to json preserves reason" `Quick
            test_action_to_json_noop;
          test_case "multistep to string" `Quick
            test_action_multistep_to_string;
        ] );
      ( "baseline",
        [
          test_case "mention returns ReplyInRoom" `Quick
            test_baseline_mention_returns_reply;
          test_case "no mention returns Noop" `Quick
            test_baseline_no_mention_returns_noop;
        ] );
      ( "deliberation_meta",
        [
          test_case "json roundtrip" `Quick
            test_deliberation_meta_json_roundtrip;
          test_case "defaults from empty json" `Quick
            test_deliberation_meta_defaults;
        ] );
      ( "policy_mode",
        [
          test_case "parse llm_deliberation" `Quick
            test_policy_mode_llm_deliberation_parse;
          test_case "llm_deliberation roundtrip" `Quick
            test_policy_mode_llm_deliberation_roundtrip;
          test_case "is_deliberation predicate" `Quick
            test_policy_mode_is_deliberation;
        ] );
      ( "keeper_meta",
        [
          test_case "deliberation fields roundtrip" `Quick
            test_keeper_meta_deliberation_fields_roundtrip;
          test_case "deliberation fields default" `Quick
            test_keeper_meta_deliberation_fields_default;
        ] );
      ( "triage_result_json",
        [
          test_case "skip json" `Quick test_triage_result_skip_json;
          test_case "triggered json" `Quick test_triage_result_triggered_json;
        ] );
      ( "world_observation",
        [
          test_case "observation to json" `Quick test_world_observation_json;
          test_case "canonical policy mode llm_deliberation" `Quick
            test_canonical_policy_mode_llm_deliberation;
          test_case "canonical policy mode heuristic" `Quick
            test_canonical_policy_mode_heuristic;
          test_case "canonical policy mode unknown" `Quick
            test_canonical_policy_mode_unknown;
        ] );
    ]
