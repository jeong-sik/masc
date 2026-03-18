open Alcotest

module Mention = Masc_mcp.Mention
module Keeper_execution = Masc_mcp.Keeper_execution
module Keeper_memory = Masc_mcp.Keeper_memory
module Keeper_types = Masc_mcp.Keeper_types
module Types = Masc_mcp.Types

let keeper_meta ~name ~mention_targets =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String "trace-1");
        ("goal", `String "keep continuity");
        ("models", `List [ `String "custom:test-model" ]);
        ("active_model", `String "custom:test-model");
        ("mention_targets", `List (List.map (fun target -> `String target) mention_targets));
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("failed to build keeper meta: " ^ err)

let room_message content =
  {
    Types.seq = 1;
    from_agent = "tester";
    msg_type = "broadcast";
    content;
    mention = None;
    timestamp = "2026-03-12T00:00:00Z";
  }

let test_any_mentioned_exact_target () =
  check bool "exact direct mention" true
    (Mention.any_mentioned ~targets:[ "sangsu" ] "hello @sangsu, are you there?")

let test_any_mentioned_ambient_message () =
  check bool "ambient message not a direct mention" false
    (Mention.any_mentioned ~targets:[ "sangsu" ] "hello everyone, just chatting")

let test_keeper_policy_observation_direct_mention () =
  let meta = keeper_meta ~name:"sangsu" ~mention_targets:[ "sangsu"; "director" ] in
  let obs =
    Keeper_memory.keeper_policy_observation_of_room_message
      ~meta ~room_id:"default" (room_message "@director, what do you think?")
  in
  check bool "keeper observation uses mention targets" true obs.direct_mention

let test_keeper_policy_observation_non_mention () =
  let meta = keeper_meta ~name:"sangsu" ~mention_targets:[ "sangsu"; "director" ] in
  let obs =
    Keeper_memory.keeper_policy_observation_of_room_message
      ~meta ~room_id:"default" (room_message "ambient room chatter")
  in
  check bool "keeper observation no longer hardcodes direct mention" false obs.direct_mention

let test_user_visible_reply_strips_state_block () =
  let raw =
    "좋아요. 이어서 진행하겠습니다.\n\n[STATE]\nGoal: keep continuity\nProgress: ready\n[/STATE]"
  in
  check string "state block hidden from user text"
    "좋아요. 이어서 진행하겠습니다."
    (Keeper_execution.user_visible_reply_text raw)

let test_user_visible_reply_strips_skill_and_state_markers () =
  let raw =
    "SKILL: scene-director\nSKILL_REASON: continuity\n본문입니다.\n\n[STATE]\nGoal: keep continuity\n[/STATE]"
  in
  check string "skill route lines hidden from user text"
    "본문입니다."
    (Keeper_execution.user_visible_reply_text raw)

let test_user_visible_reply_falls_back_to_snapshot_progress () =
  let raw =
    "[STATE]\nGoal: keep continuity\nProgress: 다음 장면 전환 준비 완료\n[/STATE]"
  in
  check string "state-only reply falls back to progress"
    "다음 장면 전환 준비 완료"
    (Keeper_execution.user_visible_reply_text raw)

(* Recall is private; access via Keeper_memory which includes it *)
module Recall = Masc_mcp.Keeper_memory

(* Helper to build a keeper_auto_rule_eval with all flags off *)
let base_eval : Recall.keeper_auto_rule_eval = {
  repetition_risk = 0.0;
  goal_alignment = 1.0;
  response_alignment = 1.0;
  goal_drift = 0.0;
  reflect = false;
  plan = false;
  compact = false;
  handoff = false;
  guardrail_stop = false;
  guardrail_reason = None;
  reasons = [];
}

let test_prioritized_action_none () =
  let action = Recall.prioritized_action base_eval in
  check string "no rule fired" "none"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_guardrail_stop () =
  let eval = { base_eval with
    guardrail_stop = true;
    guardrail_reason = Some "all gates triggered";
    reflect = true;
    plan = true;
    compact = true;
    handoff = true;
  } in
  let action = Recall.prioritized_action eval in
  match action with
  | Recall.Act_guardrail_stop reason ->
      check bool "reason contains gates" true
        (String.length reason > 0)
  | _ -> fail "expected Act_guardrail_stop"

let test_prioritized_action_reflect_over_plan () =
  let eval = { base_eval with
    reflect = true;
    plan = true;
    compact = true;
  } in
  let action = Recall.prioritized_action eval in
  check string "reflect wins over plan" "reflect"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_plan_over_compact () =
  let eval = { base_eval with
    plan = true;
    compact = true;
    handoff = true;
  } in
  let action = Recall.prioritized_action eval in
  check string "plan wins over compact" "plan"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_compact_over_handoff () =
  let eval = { base_eval with
    compact = true;
    handoff = true;
  } in
  let action = Recall.prioritized_action eval in
  check string "compact wins over handoff" "compact"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_handoff_alone () =
  let eval = { base_eval with handoff = true } in
  let action = Recall.prioritized_action eval in
  check string "handoff alone" "handoff"
    (Recall.prioritized_action_to_string action)

let test_prioritized_action_guardrail_default_reason () =
  let eval = { base_eval with
    guardrail_stop = true;
    guardrail_reason = None;
  } in
  let action = Recall.prioritized_action eval in
  match action with
  | Recall.Act_guardrail_stop reason ->
      check string "default reason" "guardrail_stop" reason
  | _ -> fail "expected Act_guardrail_stop"

let test_prioritized_action_to_string_all_variants () =
  let open Recall in
  check string "guardrail" "guardrail_stop(safety)" (prioritized_action_to_string (Act_guardrail_stop "safety"));
  check string "reflect" "reflect" (prioritized_action_to_string Act_reflect);
  check string "plan" "plan" (prioritized_action_to_string Act_plan);
  check string "compact" "compact" (prioritized_action_to_string Act_compact);
  check string "handoff" "handoff" (prioritized_action_to_string Act_handoff);
  check string "none" "none" (prioritized_action_to_string Act_none)

let () =
  run "Keeper_memory"
    [
      ( "mention",
        [
          test_case "any_mentioned exact target" `Quick test_any_mentioned_exact_target;
          test_case "any_mentioned ambient message" `Quick test_any_mentioned_ambient_message;
          test_case "policy observation direct mention" `Quick
            test_keeper_policy_observation_direct_mention;
          test_case "policy observation ambient message" `Quick
            test_keeper_policy_observation_non_mention;
          test_case "user visible reply strips state block" `Quick
            test_user_visible_reply_strips_state_block;
          test_case "user visible reply strips skill and state markers" `Quick
            test_user_visible_reply_strips_skill_and_state_markers;
          test_case "user visible reply falls back to snapshot progress" `Quick
            test_user_visible_reply_falls_back_to_snapshot_progress;
        ] );
      ( "prioritized_action",
        [
          test_case "none when no rules fire" `Quick test_prioritized_action_none;
          test_case "guardrail_stop highest priority" `Quick test_prioritized_action_guardrail_stop;
          test_case "reflect over plan" `Quick test_prioritized_action_reflect_over_plan;
          test_case "plan over compact" `Quick test_prioritized_action_plan_over_compact;
          test_case "compact over handoff" `Quick test_prioritized_action_compact_over_handoff;
          test_case "handoff alone" `Quick test_prioritized_action_handoff_alone;
          test_case "guardrail default reason" `Quick test_prioritized_action_guardrail_default_reason;
          test_case "to_string all variants" `Quick test_prioritized_action_to_string_all_variants;
        ] );
    ]
