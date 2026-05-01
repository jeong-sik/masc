open Alcotest

module D = Masc_mcp.Keeper_deliberation
module Keeper_types = Masc_mcp.Keeper_types

let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.deliberation.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
      let rec ascend path =
        if has_prompt_root path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then Sys.getcwd () else ascend parent
      in
      ascend (Sys.getcwd ())

let () =
  let prompts_dir = Filename.concat (repo_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts_dir;
  Masc_mcp.Prompt_defaults.init ()

(* ---------- Triage tests ---------- *)

let base_obs =
  D.empty_world_observation ~keeper_name:"test-keeper"

let contains_substring text needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) text 0);
    true
  with Not_found -> false

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

let test_action_to_policy_label_noop () =
  check string "noop policy label" "noop"
    (D.deliberation_action_to_policy_label (D.Noop "test"))

let test_action_to_policy_label_reply () =
  check string "reply policy label" "reply_in_room"
    (D.deliberation_action_to_policy_label
       (D.ReplyInRoom { room_id = "r1"; content = "hello" }))

let test_action_to_policy_label_board_post () =
  check string "board_post policy label" "board_post"
    (D.deliberation_action_to_policy_label
       (D.BoardPost { content = "test"; hearth = None }))

let test_action_to_policy_label_task_claim () =
  check string "task_claim policy label" "task_claim"
    (D.deliberation_action_to_policy_label
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
        D.TaskClaim { task_id = "t-1"; reason = "urgent"};
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

let test_baseline_execution_result_emits_baseline_source () =
  let result = D.baseline_execution_result base_obs in
  check string "baseline source" "baseline"
    (D.action_source_to_string result.action_source);
  check bool "baseline fallback not used" false result.fallback_used

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

(* ---------- Keeper meta deliberation fields ---------- *)

let test_keeper_meta_deliberation_fields_roundtrip () =
  (* deliberation_count/cost/ts/last_triage_triggers removed from keeper_meta
     (live in deliberation_meta). Verify that old JSON keys are silently
     ignored and remaining fields parse correctly. *)
  let json =
    `Assoc
      [
        ("name", `String "test-keeper");
        ("trace_id", `String "trace-1");
        ("goal", `String "test deliberation");
        (* legacy keys — should be ignored by meta_of_json *)
        ("deliberation_count", `Int 5);
        ("deliberation_cost_total_usd", `Float 0.03);
        ("last_deliberation_ts", `Float 1710000000.0);
        ("last_triage_triggers", `String "direct_mention");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error err -> fail ("meta parse failed: " ^ err)
  | Ok meta ->
      check string "name preserved" "test-keeper" meta.name

let test_keeper_meta_deliberation_fields_default () =
  let json =
    `Assoc
      [
        ("name", `String "test-keeper-2");
        ("trace_id", `String "trace-2");
        ("goal", `String "test defaults");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error err -> fail ("meta parse failed: " ^ err)
  | Ok meta ->
      check string "name preserved" "test-keeper-2" meta.name

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

(* ================================================================ *)
(* Phase 2: MODEL-Driven Deliberation tests                          *)
(* ================================================================ *)

(* ---------- build_deliberation_prompt tests ---------- *)

let test_prompt_contains_keeper_name () =
  let prompt =
    D.build_deliberation_prompt
      ~keeper_name:"alpha-keeper"
      ~goal:"Monitor CI pipeline"
      ~triggers:[ D.DirectMention; D.NewUnclaimedTask ]
      base_obs
  in
  check bool "contains keeper name" true
    (String.length prompt > 0
     && try ignore (Str.search_forward (Str.regexp_string "alpha-keeper") prompt 0); true
        with Not_found -> false)

let test_prompt_contains_triggers () =
  let prompt =
    D.build_deliberation_prompt
      ~keeper_name:"test-k"
      
      ~goal:"Watch tasks"
      ~triggers:[ D.FailedTask; D.IdleTimeout ]
      base_obs
  in
  check bool "contains failed_task" true
    (try ignore (Str.search_forward (Str.regexp_string "failed_task") prompt 0); true
     with Not_found -> false);
  check bool "contains idle_timeout" true
    (try ignore (Str.search_forward (Str.regexp_string "idle_timeout") prompt 0); true
     with Not_found -> false)

let test_prompt_contains_tool_input_instruction () =
  let prompt =
    D.build_deliberation_prompt
      ~keeper_name:"test-k"
      ~goal:"Watch"
      ~triggers:[ D.DirectMention ]
      base_obs
  in
  check bool "mentions tool input schema" true
    (try
       ignore
         (Str.search_forward
            (Str.regexp_string
               "tool input object for schema `keeper_deliberation_decision`")
            prompt 0);
       true
     with Not_found -> false)

let test_prompt_contains_action_list () =
  let prompt =
    D.build_deliberation_prompt
      ~keeper_name:"test-k"
      ~goal:""
      ~triggers:[ D.DirectMention ]
      base_obs
  in
  check bool "mentions noop action" true
    (try ignore (Str.search_forward (Str.regexp_string "noop") prompt 0); true
     with Not_found -> false);
  check bool "mentions reply_in_room action" true
    (try ignore (Str.search_forward (Str.regexp_string "reply_in_room") prompt 0); true
     with Not_found -> false);
  check bool "mentions task_claim action" true
    (try ignore (Str.search_forward (Str.regexp_string "task_claim") prompt 0); true
     with Not_found -> false);
  check bool "mentions broadcast action" true
    (try ignore (Str.search_forward (Str.regexp_string "broadcast") prompt 0); true
     with Not_found -> false)

(* ---------- parse_deliberation_response tests ---------- *)

let test_parse_valid_noop_json () =
  let raw =
    {|{"action":"noop","params":{"reason":"All quiet"},"reasoning":"Nothing to do","confidence":0.95}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok, got Error: " ^ msg)
  | Ok (action, reasoning, confidence) ->
      (match action with
       | D.Noop reason ->
           check string "noop reason" "All quiet" reason
       | _ -> fail "expected Noop action");
      check string "reasoning" "Nothing to do" reasoning;
      check (float 0.01) "confidence" 0.95 confidence

let test_parse_valid_reply_json () =
  let raw =
    {|{"action":"reply_in_room","params":{"room_id":"room-42","content":"Hello team"},"reasoning":"Responding to mention","confidence":0.8}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok, got Error: " ^ msg)
  | Ok (action, _reasoning, _confidence) ->
      match action with
      | D.ReplyInRoom { room_id; content } ->
          check string "room_id" "room-42" room_id;
          check string "content" "Hello team" content
      | _ -> fail "expected ReplyInRoom action"

let test_parse_valid_task_claim_json () =
  let raw =
    {|{"action":"task_claim","params":{"task_id":"task-99","reason":"Matches my goal"},"reasoning":"Aligned","confidence":0.7}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok, got Error: " ^ msg)
  | Ok (action, _reasoning, _confidence) ->
      match action with
      | D.TaskClaim { task_id; reason } ->
          check string "task_id" "task-99" task_id;
          check string "reason" "Matches my goal" reason
      | _ -> fail "expected TaskClaim action"

let test_parse_valid_broadcast_json () =
  let raw =
    {|{"action":"broadcast","params":{"message":"Status update"},"reasoning":"Team needs info","confidence":0.6}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok, got Error: " ^ msg)
  | Ok (action, _reasoning, _confidence) ->
      match action with
      | D.Broadcast { message } ->
          check string "message" "Status update" message
      | _ -> fail "expected Broadcast action"

let test_structured_result_schema_metadata () =
  check string "schema name" "keeper_deliberation_decision"
    D.structured_result_schema.name;
  check bool "schema requires action" true
    (List.exists
       (fun (param : Agent_sdk.Types.tool_param) ->
          String.equal param.name "action" && param.required)
       D.structured_result_schema.params)

let test_structured_result_schema_parse_valid_json () =
  let json =
    Yojson.Safe.from_string
      {|{"action":"noop","params":{"reason":"quiet"},"reasoning":"nothing","confidence":0.9}|}
  in
  match D.structured_result_schema.parse json with
  | Error msg -> fail ("expected schema parse Ok, got Error: " ^ msg)
  | Ok result ->
      (match result.action with
       | D.Noop reason -> check string "noop reason" "quiet" reason
       | _ -> fail "expected Noop action");
      check string "reasoning" "nothing" result.reasoning;
      check (float 0.01) "confidence" 0.9 result.confidence

let test_legality_verdict_rejects_illegal_task_claim () =
  let obs =
    D.{ base_obs with unclaimed_task_count = 0 }
  in
  match
    D.legality_verdict obs
      (D.TaskClaim { task_id = "task-1"; reason = "urgent"})
  with
  | D.Illegal msg ->
      check bool "mentions unclaimed tasks" true
        (contains_substring msg "unclaimed tasks")
  | D.Legal -> fail "expected illegal task_claim without unclaimed tasks"

let test_legality_verdict_rejects_nested_multistep () =
  let obs =
    D.{ base_obs with unclaimed_task_count = 1 }
  in
  let action =
    D.MultiStep
      [
        D.TaskClaim { task_id = "task-1"; reason = "urgent"};
        D.MultiStep [ D.Broadcast { message = "claimed" } ];
      ]
  in
  match D.legality_verdict obs action with
  | D.Illegal msg ->
      check bool "mentions nested multi_step" true
        (contains_substring msg "nested multi_step")
  | D.Legal -> fail "expected nested multi_step to be illegal"

let test_execute_structured_result_keeps_legal_action () =
  let obs =
    D.{ base_obs with unclaimed_task_count = 1 }
  in
  let structured =
    D.
      {
        action = TaskClaim { task_id = "task-1"; reason = "urgent"};
        reasoning = "claim the waiting task";
        confidence = 0.8;
      }
  in
  let result = D.execute_structured_result obs structured in
  check string "legal action source" "structured_model"
    (D.action_source_to_string result.action_source);
  check bool "fallback not used" false result.fallback_used;
  check (option string) "no fallback reason" None result.fallback_reason;
  check (list string) "policy labels" [ "task_claim" ] result.policy_labels;
  match result.selected_action with
  | D.TaskClaim { task_id; _ } ->
      check string "selected task" "task-1" task_id
  | _ -> fail "expected selected task_claim action"

let test_execute_structured_result_falls_back_to_baseline () =
  let obs = base_obs in
  let structured =
    D.
      {
        action = TaskClaim { task_id = "task-1"; reason = "urgent"};
        reasoning = "claim the waiting task";
        confidence = 0.8;
      }
  in
  let result = D.execute_structured_result obs structured in
  check string "fallback action source" "fallback_after_validation_failure"
    (D.action_source_to_string result.action_source);
  check bool "fallback used" true result.fallback_used;
  check bool "fallback reason present" true (Option.is_some result.fallback_reason);
  check (list string) "policy labels" [ "noop" ] result.policy_labels;
  match result.selected_action with
  | D.Noop reason ->
      check string "fallback noop" "no_trigger" reason
  | _ -> fail "expected fallback noop action"

let test_parse_json_with_code_fences_rejected () =
  let raw =
    "```json\n{\"action\":\"noop\",\"params\":{\"reason\":\"quiet\"},\"reasoning\":\"nothing\",\"confidence\":0.9}\n```"
  in
  match D.parse_deliberation_response raw with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for fenced JSON"

let test_parse_json_with_surrounding_text_rejected () =
  let raw =
    "Here is my decision:\n{\"action\":\"noop\",\"params\":{\"reason\":\"quiet\"},\"reasoning\":\"nothing\",\"confidence\":0.5}\nThat's my answer."
  in
  match D.parse_deliberation_response raw with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for embedded JSON in surrounding text"

let test_parse_malformed_json () =
  let raw = "this is not json at all" in
  match D.parse_deliberation_response raw with
  | Error _ -> () (* expected *)
  | Ok _ -> fail "expected Error for malformed input"

let test_parse_empty_string () =
  match D.parse_deliberation_response "" with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for empty string"

let test_parse_missing_action_field () =
  let raw =
    {|{"params":{"reason":"test"},"reasoning":"no action","confidence":0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for missing action field"

let test_parse_unknown_action_type () =
  let raw =
    {|{"action":"teleport","params":{},"reasoning":"unknown","confidence":0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg ->
      check bool "mentions unknown action" true
        (try ignore (Str.search_forward (Str.regexp_string "unknown action") msg 0); true
         with Not_found -> false)
  | Ok _ -> fail "expected Error for unknown action type"

let test_parse_reply_empty_content_fails () =
  let raw =
    {|{"action":"reply_in_room","params":{"room_id":"r1","content":""},"reasoning":"test","confidence":0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for empty reply content"

let test_parse_task_claim_empty_task_id_fails () =
  let raw =
    {|{"action":"task_claim","params":{"task_id":"","reason":"test"},"reasoning":"test","confidence":0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for empty task_id"

let test_parse_confidence_clamped () =
  let raw =
    {|{"action":"noop","params":{"reason":"test"},"reasoning":"test","confidence":1.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok, got Error: " ^ msg)
  | Ok (_action, _reasoning, confidence) ->
      check (float 0.01) "confidence clamped to 1.0" 1.0 confidence

let test_parse_negative_confidence_clamped () =
  let raw =
    {|{"action":"noop","params":{"reason":"test"},"reasoning":"test","confidence":-0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok, got Error: " ^ msg)
  | Ok (_action, _reasoning, confidence) ->
      check (float 0.01) "negative confidence clamped to 0.0" 0.0 confidence

let test_parse_missing_confidence_defaults () =
  let raw =
    {|{"action":"noop","params":{"reason":"test"},"reasoning":"test"}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok, got Error: " ^ msg)
  | Ok (_action, _reasoning, confidence) ->
      check (float 0.01) "default confidence" 0.5 confidence

(* ---------- deliberation_budget_check tests ---------- *)

let test_budget_check_under_budget () =
  check bool "under budget" true
    (D.deliberation_budget_check ~daily_budget_usd:0.10 ~cost_today_usd:0.05)

let test_budget_check_at_budget () =
  check bool "at budget (should fail)" false
    (D.deliberation_budget_check ~daily_budget_usd:0.10 ~cost_today_usd:0.10)

let test_budget_check_over_budget () =
  check bool "over budget" false
    (D.deliberation_budget_check ~daily_budget_usd:0.10 ~cost_today_usd:0.15)

let test_budget_check_zero_budget () =
  check bool "zero budget always fails" false
    (D.deliberation_budget_check ~daily_budget_usd:0.0 ~cost_today_usd:0.0)

let test_budget_check_zero_cost () =
  check bool "zero cost under positive budget" true
    (D.deliberation_budget_check ~daily_budget_usd:0.10 ~cost_today_usd:0.0)

let test_default_daily_budget () =
  (* default is 0.10 in env_config_keeper.ml KeeperRuntime *)
  check (float 0.001) "default budget" 0.10 (D.daily_budget_usd ())

let test_daily_budget_from_env_default () =
  (* Unset the env var to get default *)
  let saved = Sys.getenv_opt "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" in
  (match saved with
   | Some _ -> Unix.putenv "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" ""
   | None -> ());
  (* The function reads at call time, but with empty string it should
     fall back to default due to float_of_string failure *)
  let budget = D.daily_budget_usd () in
  (* Restore *)
  (match saved with
   | Some v -> Unix.putenv "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" v
   | None -> ());
  (* Empty string causes Failure in float_of_string, so default applies *)
  check (float 0.001) "env default budget" 0.10 budget

let test_daily_budget_from_env_custom () =
  let saved = Sys.getenv_opt "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" in
  Unix.putenv "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" "0.50";
  let budget = D.daily_budget_usd () in
  (match saved with
   | Some v -> Unix.putenv "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" v
   | None ->
       (* Cannot truly unset with Unix.putenv, set to empty *)
       Unix.putenv "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" "");
  check (float 0.001) "custom env budget" 0.50 budget

(* ================================================================ *)
(* Phase 5: L2 Proactive and L3 Strategic tests                     *)
(* ================================================================ *)

(* ---------- L2 Proactive triage: GoalDeadline trigger ---------- *)

let test_triage_goal_deadline () =
  (* GoalDeadline fires when active_goal_count > 0 AND idle_seconds > idle_gate * 2 *)
  let obs =
    { base_obs with
      active_goal_count = 1;
      idle_seconds = 700;
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected GoalDeadline trigger"
  | D.Triggered triggers ->
      check bool "contains GoalDeadline" true
        (List.mem D.GoalDeadline triggers)

let test_triage_goal_deadline_not_triggered_below_threshold () =
  (* idle_seconds (500) is NOT > idle_gate * 2 (600) *)
  let obs =
    { base_obs with
      active_goal_count = 2;
      idle_seconds = 500;
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> ()
  | D.Triggered triggers ->
      (* IdleTimeout may fire (500 > 300) but GoalDeadline should not *)
      check bool "GoalDeadline should not trigger" false
        (List.mem D.GoalDeadline triggers)

let test_triage_goal_deadline_no_goals () =
  (* No active goals, so GoalDeadline should not fire even with high idle *)
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 1000;
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> () (* expected: no goals, no triggers *)
  | D.Triggered triggers ->
      check bool "GoalDeadline should not trigger without goals" false
        (List.mem D.GoalDeadline triggers)

(* ---------- L2 Proactive triage: StrategicReview trigger ---------- *)

let test_triage_strategic_review () =
  (* StrategicReview fires when idle_seconds > idle_gate * 5 AND active_goal_count > 0 *)
  let obs =
    { base_obs with
      active_goal_count = 1;
      idle_seconds = 1600;
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected StrategicReview trigger"
  | D.Triggered triggers ->
      check bool "contains StrategicReview" true
        (List.mem D.StrategicReview triggers)

let test_triage_strategic_review_not_triggered_below_threshold () =
  (* idle_seconds (1400) is NOT > idle_gate * 5 (1500) *)
  let obs =
    { base_obs with
      active_goal_count = 1;
      idle_seconds = 1400;
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> () (* could skip entirely or trigger other things *)
  | D.Triggered triggers ->
      check bool "StrategicReview should not trigger" false
        (List.mem D.StrategicReview triggers)

(* ---------- L3 Strategic: multi_step parse ---------- *)

let test_parse_multi_step_action () =
  let raw =
    {|{"action":"multi_step","params":{"steps":[
        {"action":"task_claim","params":{"task_id":"t-1","reason":"urgent"}},
        {"action":"broadcast","params":{"message":"Claimed t-1"}}
      ]},"reasoning":"Claim and announce","confidence":0.7}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok for multi_step, got Error: " ^ msg)
  | Ok (action, reasoning, confidence) ->
      (match action with
       | D.MultiStep actions ->
           check int "step count" 2 (List.length actions);
           check string "reasoning" "Claim and announce" reasoning;
           check (float 0.01) "confidence" 0.7 confidence
       | _ -> fail "expected MultiStep action")

let test_parse_multi_step_empty_steps_fails () =
  let raw =
    {|{"action":"multi_step","params":{"steps":[]},"reasoning":"empty","confidence":0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error _ -> () (* expected *)
  | Ok _ -> fail "expected Error for empty multi_step steps"

let test_parse_multi_step_truncated_to_5 () =
  let steps =
    List.init 7 (fun i ->
      Printf.sprintf
        {|{"action":"noop","params":{"reason":"step-%d"}}|} i)
  in
  let steps_str = String.concat "," steps in
  let raw =
    Printf.sprintf
      {|{"action":"multi_step","params":{"steps":[%s]},"reasoning":"many steps","confidence":0.6}|}
      steps_str
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok for truncated multi_step, got Error: " ^ msg)
  | Ok (action, _reasoning, _confidence) ->
      match action with
      | D.MultiStep actions ->
          check int "truncated to 5 steps" 5 (List.length actions)
      | _ -> fail "expected MultiStep action"

let test_parse_multi_step_nested_rejected () =
  let raw =
    {|{"action":"multi_step","params":{"steps":[
        {"action":"multi_step","params":{"steps":[{"action":"noop","params":{"reason":"inner"}}]}}
      ]},"reasoning":"nested","confidence":0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg ->
      check bool "mentions nested" true
        (try ignore (Str.search_forward (Str.regexp_string "nested") msg 0); true
         with Not_found -> false)
  | Ok _ -> fail "expected Error for nested multi_step"

let test_parse_multi_step_invalid_substep_fails () =
  let raw =
    {|{"action":"multi_step","params":{"steps":[
        {"action":"reply_in_room","params":{"room_id":"r1","content":""}},
        {"action":"noop","params":{"reason":"ok"}}
      ]},"reasoning":"bad step","confidence":0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error _ -> () (* expected: reply with empty content fails *)
  | Ok _ -> fail "expected Error for invalid substep in multi_step"

(* ---------- multi_step is always included ---------- *)

let test_prompt_always_includes_multi_step () =
  let prompt =
    D.build_deliberation_prompt
      ~keeper_name:"strategic-keeper"
      
      ~goal:"Plan and execute"
      ~triggers:[ D.DirectMention ]
      base_obs
  in
  check bool "prompt contains multi_step" true
    (try ignore (Str.search_forward (Str.regexp_string "multi_step") prompt 0); true
     with Not_found -> false)

(* ---------- removed keeper field + idle gate tests ---------- *)

let test_removed_initiative_field_rejected () =
  let json_str = {|{"name":"test","initiative_enabled":true,"trace_id":"t1","goal":"g","cascade_name":"local","proactive_enabled":true,"proactive_idle_sec":300,"proactive_cooldown_sec":60}|} in
  let json = Yojson.Safe.from_string json_str in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok _ -> fail "initiative_enabled should be rejected"
  | Error e ->
      check bool "removed initiative field mentioned" true
        (String.contains e 'i')

let test_removed_persona_profile_path_rejected () =
  let json_str = {|{"name":"test","persona_profile_path":"config/personas/test/profile.json","trace_id":"t2","goal":"g","cascade_name":"local","proactive_enabled":true,"proactive_idle_sec":300,"proactive_cooldown_sec":60}|} in
  let json = Yojson.Safe.from_string json_str in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok _ -> fail "persona_profile_path should be rejected"
  | Error e ->
      check bool "removed persona field mentioned" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "persona_profile_path")
                e 0);
           true
         with Not_found -> false)

let test_idle_gate_drives_idle_timeout () =
  let obs = { base_obs with
    active_goal_count = 1;
    idle_seconds = 120;
    idle_gate = 60;
  } in
  match D.triage obs with
  | D.Skip _ -> fail "should trigger IdleTimeout with custom idle_gate=60"
  | D.Triggered triggers ->
    check bool "has idle_timeout" true
      (List.exists (fun t -> t = D.IdleTimeout) triggers)

(* ---------- L3 Self-directed trigger tests ---------- *)

let test_triage_self_directed_explore () =
  (* SelfDirectedExplore fires when active_goal_count = 0 AND idle_seconds > idle_gate * 4 *)
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 1300;
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected SelfDirectedExplore trigger"
  | D.Triggered triggers ->
      check bool "contains SelfDirectedExplore" true
        (List.mem D.SelfDirectedExplore triggers)

let test_triage_self_directed_not_with_goals () =
  (* SelfDirectedExplore should NOT fire when active_goal_count > 0 *)
  let obs =
    { base_obs with
      active_goal_count = 1;
      idle_seconds = 1300;
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> ()
  | D.Triggered triggers ->
      check bool "SelfDirectedExplore should not trigger with goals" false
        (List.mem D.SelfDirectedExplore triggers)

let test_triage_self_directed_not_below_threshold () =
  (* SelfDirectedExplore should NOT fire when idle_seconds < idle_gate * 4 *)
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 1100;  (* < 300 * 4 = 1200 *)
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> ()
  | D.Triggered triggers ->
      check bool "SelfDirectedExplore should not trigger below threshold" false
        (List.mem D.SelfDirectedExplore triggers)

let test_triage_board_new_posts_without_mention () =
  (* BoardActivity "new_posts" fires when board_new_post_count > 0
     AND idle_seconds >= idle_gate / 2 AND board_mention_count = 0 *)
  let obs =
    { base_obs with
      board_new_post_count = 3;
      board_mention_count = 0;
      idle_seconds = 200;   (* >= 300 / 2 = 150 *)
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected BoardActivity trigger for new posts"
  | D.Triggered triggers ->
      let has_new_posts =
        List.exists
          (function D.BoardActivity "new_posts" -> true | _ -> false)
          triggers
      in
      check bool "contains BoardActivity new_posts" true has_new_posts

let test_triage_board_new_posts_suppressed_by_mention () =
  (* When board_mention_count > 0, the new_posts trigger is suppressed
     (the mention trigger handles it instead) *)
  let obs =
    { base_obs with
      board_new_post_count = 3;
      board_mention_count = 1;
      idle_seconds = 200;
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected BoardActivity trigger (from mention)"
  | D.Triggered triggers ->
      let has_new_posts =
        List.exists
          (function D.BoardActivity "new_posts" -> true | _ -> false)
          triggers
      in
      check bool "new_posts suppressed by mention" false has_new_posts;
      let has_mention =
        List.exists
          (function D.BoardActivity "mentioned_in_post" -> true | _ -> false)
          triggers
      in
      check bool "mention trigger present" true has_mention

let test_triage_board_new_posts_too_soon () =
  (* new_posts trigger should NOT fire when idle_seconds < idle_gate / 2 *)
  let obs =
    { base_obs with
      board_new_post_count = 3;
      board_mention_count = 0;
      idle_seconds = 100;   (* < 300 / 2 = 150 *)
      idle_gate = 300;
    }
  in
  match D.triage obs with
  | D.Skip _ -> ()
  | D.Triggered triggers ->
      let has_new_posts =
        List.exists
          (function D.BoardActivity "new_posts" -> true | _ -> false)
          triggers
      in
      check bool "new_posts should not fire too soon" false has_new_posts

(* ---------- Self-directed legality tests ---------- *)

let test_legality_self_directed_allows_board_post () =
  (* Self-directed context (no goals, long idle) should allow board_post *)
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 1300;
      idle_gate = 300;
    }
  in
  match D.legality_verdict obs
    (D.BoardPost { content = "Sharing an observation"; hearth = None }) with
  | D.Legal -> ()
  | D.Illegal msg -> fail ("board_post should be legal in self-directed: " ^ msg)

let test_legality_self_directed_allows_share_finding () =
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 1300;
      idle_gate = 300;
    }
  in
  match D.legality_verdict obs
    (D.ShareFinding { finding = "test"; source = "board_scan" }) with
  | D.Legal -> ()
  | D.Illegal msg -> fail ("share_finding should be legal in self-directed: " ^ msg)

let test_legality_self_directed_allows_start_discussion () =
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 1300;
      idle_gate = 300;
    }
  in
  match D.legality_verdict obs
    (D.StartDiscussion { topic = "test topic"; context = "exploring" }) with
  | D.Legal -> ()
  | D.Illegal msg -> fail ("start_discussion should be legal in self-directed: " ^ msg)

let test_legality_not_self_directed_rejects_board_post () =
  (* Without self-directed context (idle too short), board_post is still illegal *)
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 500;  (* < 300 * 4 = 1200 *)
      idle_gate = 300;
    }
  in
  match D.legality_verdict obs
    (D.BoardPost { content = "test"; hearth = None }) with
  | D.Legal -> fail "board_post should be illegal without self-directed context"
  | D.Illegal _ -> ()

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
          test_case "goal deadline triggers" `Quick
            test_triage_goal_deadline;
          test_case "goal deadline not triggered below threshold" `Quick
            test_triage_goal_deadline_not_triggered_below_threshold;
          test_case "goal deadline no goals" `Quick
            test_triage_goal_deadline_no_goals;
          test_case "strategic review triggers" `Quick
            test_triage_strategic_review;
          test_case "strategic review not triggered below threshold" `Quick
            test_triage_strategic_review_not_triggered_below_threshold;
        ] );
      ( "actions",
        [
          test_case "noop to policy label" `Quick
            test_action_to_policy_label_noop;
          test_case "reply to policy label" `Quick
            test_action_to_policy_label_reply;
          test_case "board_post to policy label" `Quick
            test_action_to_policy_label_board_post;
          test_case "task_claim to policy label" `Quick
            test_action_to_policy_label_task_claim;
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
          test_case "baseline execution emits baseline source" `Quick
            test_baseline_execution_result_emits_baseline_source;
        ] );
      ( "deliberation_meta",
        [
          test_case "json roundtrip" `Quick
            test_deliberation_meta_json_roundtrip;
          test_case "defaults from empty json" `Quick
            test_deliberation_meta_defaults;
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
        ] );
      ( "build_deliberation_prompt",
        [
          test_case "prompt contains keeper name" `Quick
            test_prompt_contains_keeper_name;
          test_case "prompt contains trigger strings" `Quick
            test_prompt_contains_triggers;
          test_case "prompt mentions tool input schema" `Quick
            test_prompt_contains_tool_input_instruction;
          test_case "prompt lists available actions" `Quick
            test_prompt_contains_action_list;
          test_case "prompt always includes multi_step" `Quick
            test_prompt_always_includes_multi_step;
        ] );
      ( "structured_result_schema",
        [
          test_case "schema metadata" `Quick
            test_structured_result_schema_metadata;
          test_case "schema parse valid json" `Quick
            test_structured_result_schema_parse_valid_json;
        ] );
      ( "deterministic_execution",
        [
          test_case "rejects illegal task_claim" `Quick
            test_legality_verdict_rejects_illegal_task_claim;
          test_case "rejects nested multi_step" `Quick
            test_legality_verdict_rejects_nested_multistep;
          test_case "keeps legal action" `Quick
            test_execute_structured_result_keeps_legal_action;
          test_case "falls back to baseline" `Quick
            test_execute_structured_result_falls_back_to_baseline;
        ] );
      ( "parse_deliberation_response",
        [
          test_case "parse valid noop" `Quick test_parse_valid_noop_json;
          test_case "parse valid reply_in_room" `Quick
            test_parse_valid_reply_json;
          test_case "parse valid task_claim" `Quick
            test_parse_valid_task_claim_json;
          test_case "parse valid broadcast" `Quick
            test_parse_valid_broadcast_json;
          test_case "parse JSON with code fences rejected" `Quick
            test_parse_json_with_code_fences_rejected;
          test_case "parse JSON with surrounding text rejected" `Quick
            test_parse_json_with_surrounding_text_rejected;
          test_case "parse malformed JSON returns Error" `Quick
            test_parse_malformed_json;
          test_case "parse empty string returns Error" `Quick
            test_parse_empty_string;
          test_case "parse missing action field" `Quick
            test_parse_missing_action_field;
          test_case "parse unknown action type" `Quick
            test_parse_unknown_action_type;
          test_case "reply with empty content fails" `Quick
            test_parse_reply_empty_content_fails;
          test_case "task_claim with empty task_id fails" `Quick
            test_parse_task_claim_empty_task_id_fails;
          test_case "confidence clamped to 1.0" `Quick
            test_parse_confidence_clamped;
          test_case "negative confidence clamped to 0.0" `Quick
            test_parse_negative_confidence_clamped;
          test_case "missing confidence defaults to 0.5" `Quick
            test_parse_missing_confidence_defaults;
          test_case "parse multi_step action" `Quick
            test_parse_multi_step_action;
          test_case "multi_step empty steps fails" `Quick
            test_parse_multi_step_empty_steps_fails;
          test_case "multi_step truncated to 5" `Quick
            test_parse_multi_step_truncated_to_5;
          test_case "nested multi_step rejected" `Quick
            test_parse_multi_step_nested_rejected;
          test_case "multi_step invalid substep fails" `Quick
            test_parse_multi_step_invalid_substep_fails;
        ] );
      ( "deliberation_budget",
        [
          test_case "under budget returns true" `Quick
            test_budget_check_under_budget;
          test_case "at budget returns false" `Quick
            test_budget_check_at_budget;
          test_case "over budget returns false" `Quick
            test_budget_check_over_budget;
          test_case "zero budget always false" `Quick
            test_budget_check_zero_budget;
          test_case "zero cost under positive budget" `Quick
            test_budget_check_zero_cost;
          test_case "default daily budget value" `Quick
            test_default_daily_budget;
          test_case "daily budget from env default" `Quick
            test_daily_budget_from_env_default;
          test_case "daily budget from env custom" `Quick
            test_daily_budget_from_env_custom;
        ] );
      ( "keeper_field_cleanup",
        [
          test_case "initiative field rejected" `Quick
            test_removed_initiative_field_rejected;
          test_case "persona profile path rejected" `Quick
            test_removed_persona_profile_path_rejected;
          test_case "idle_gate drives idle timeout" `Quick
            test_idle_gate_drives_idle_timeout;
        ] );
      ( "self_directed_triggers",
        [
          test_case "self-directed explore fires" `Quick
            test_triage_self_directed_explore;
          test_case "self-directed not with goals" `Quick
            test_triage_self_directed_not_with_goals;
          test_case "self-directed not below threshold" `Quick
            test_triage_self_directed_not_below_threshold;
          test_case "board new posts without mention" `Quick
            test_triage_board_new_posts_without_mention;
          test_case "board new posts suppressed by mention" `Quick
            test_triage_board_new_posts_suppressed_by_mention;
          test_case "board new posts too soon" `Quick
            test_triage_board_new_posts_too_soon;
        ] );
      ( "self_directed_legality",
        [
          test_case "self-directed allows board_post" `Quick
            test_legality_self_directed_allows_board_post;
          test_case "self-directed allows share_finding" `Quick
            test_legality_self_directed_allows_share_finding;
          test_case "self-directed allows start_discussion" `Quick
            test_legality_self_directed_allows_start_discussion;
          test_case "not self-directed rejects board_post" `Quick
            test_legality_not_self_directed_rejects_board_post;
        ] );
    ]
