open Alcotest

module D = Masc.Keeper_deliberation
module R = Masc.Keeper_delegation_request
module RS = Masc.Keeper_delegation_request_store
module Keeper_types = Keeper_types

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
  Masc.Prompt_defaults.init ()

let temp_dir () = Filename.temp_dir "keeper_delegation_request_store_test" ""

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

(* ---------- Triage tests ---------- *)

let base_obs =
  D.empty_world_observation ~keeper_name:"test-keeper"

let contains_substring text needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) text 0);
    true
  with Not_found -> false

let json_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_string_field key json =
  match json_field key json with
  | Some (`String value) -> value
  | _ -> fail ("expected string field " ^ key)

let json_list_items label = function
  | `List items -> items
  | _ -> fail ("expected JSON list for " ^ label)

let test_triage_skip_on_empty_observation () =
  let result = D.triage base_obs in
  match result with
  | D.Skip _ -> fail "empty observations must still cross the model boundary"
  | D.Triggered triggers -> check (list string) "no labels required" []
      (List.map D.deliberation_trigger_to_string triggers)

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

(* Failed task state is a raw observation. The configured model decides what
   to do with it; local tool semantics must not suppress the trigger. *)
let test_triage_failed_task_is_a_trigger () =
  let obs = { base_obs with failed_task_count = 1 } in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for failed task"
  | D.Triggered triggers ->
      check bool "failed_task is a trigger" true
        (List.mem D.FailedTask triggers)

let test_triage_keeper_fiber_count_change () =
  let obs = { base_obs with keeper_fiber_count_changed = true } in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for keeper fiber count change"
  | D.Triggered triggers ->
      check bool "contains KeeperFiberStartedOrStopped" true
        (List.mem D.KeeperFiberStartedOrStopped triggers)

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
    { base_obs with idle_seconds = 600; active_goal_count = 2 }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected Triggered for idle timeout with goals"
  | D.Triggered triggers ->
      check bool "contains IdleTimeout" true
        (List.mem D.IdleTimeout triggers)

let test_triage_idle_without_goals_skips () =
  let obs =
    { base_obs with idle_seconds = 600; active_goal_count = 0 }
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
      keeper_fiber_count_changed = true;
    }
  in
  match D.triage obs with
  | D.Skip _ -> fail "expected multiple triggers"
  | D.Triggered triggers ->
      check bool "at least 3 triggers" true (List.length triggers >= 3);
      check bool "failed_task remains an observed signal" true
        (List.mem D.FailedTask triggers)

(* ---------- Action type tests ---------- *)

let test_action_to_policy_label_noop () =
  check string "noop policy label" "noop"
    (D.deliberation_action_to_policy_label (D.Noop "test"))

let test_action_to_policy_label_board_post () =
  check string "board_post policy label" "board_post"
    (D.deliberation_action_to_policy_label
       (D.BoardPost { content = "test"; hearth = None }))

let test_action_to_policy_label_task_claim () =
  check string "task_claim policy label" "task_claim"
    (D.deliberation_action_to_policy_label
       (D.TaskClaim { task_id = "t-1"; reason = "needed" }))

let test_action_to_policy_label_task_create () =
  check string "task_create policy label" "task_create"
    (D.deliberation_action_to_policy_label
       (D.TaskCreate
          {
            title = "Create scoped task";
            description = "Seed active goal work";
            priority = Some 2;
          }))

let test_action_to_json_roundtrip () =
  let action = D.BoardPost { content = "hello"; hearth = None } in
  let json = D.deliberation_action_to_json action in
  let typ =
    Yojson.Safe.Util.member "type" json |> Yojson.Safe.Util.to_string
  in
  check string "json type field" "board_post" typ

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

let test_baseline_mention_returns_noop () =
  let obs = { base_obs with direct_mention = true } in
  let action = D.deterministic_baseline_action obs in
  match action with
  | D.Noop _ -> ()
  | _ -> fail "expected Noop for direct mention"

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
  let json = D.triage_result_to_json (D.Skip "quiet workspace") in
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
  check bool "mentions task_claim action" true
    (try ignore (Str.search_forward (Str.regexp_string "task_claim") prompt 0); true
     with Not_found -> false);
  check bool "mentions task_create action" true
    (try ignore (Str.search_forward (Str.regexp_string "task_create") prompt 0); true
     with Not_found -> false);
  check bool "mentions broadcast action" true
    (try ignore (Str.search_forward (Str.regexp_string "broadcast") prompt 0); true
     with Not_found -> false);
  check bool "mentions delegation request semantics" true
    (contains_substring prompt "does not directly spawn an agent")

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

let test_parse_valid_task_create_json () =
  let raw =
    {|{"action":"task_create","params":{"title":"Add focused regression test","description":"Create a narrow test for active-goal task seeding.","priority":2},"reasoning":"Active goal has no claimable task","confidence":0.72}|}
  in
  match D.parse_deliberation_response raw with
  | Error msg -> fail ("expected Ok, got Error: " ^ msg)
  | Ok (action, reasoning, confidence) ->
      (match action with
       | D.TaskCreate { title; description; priority } ->
           check string "title" "Add focused regression test" title;
           check string "description" "Create a narrow test for active-goal task seeding." description;
           check (option int) "priority" (Some 2) priority
       | _ -> fail "expected TaskCreate action");
      check string "reasoning" "Active goal has no claimable task" reasoning;
      check (float 0.01) "confidence" 0.72 confidence

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

let test_legality_verdict_accepts_model_task_claim () =
  let obs =
    D.{ base_obs with unclaimed_task_count = 0 }
  in
  match
    D.legality_verdict obs
      (D.TaskClaim { task_id = "task-1"; reason = "urgent"})
  with
  | D.Illegal msg -> fail ("model task_claim was locally rejected: " ^ msg)
  | D.Legal -> ()

let test_legality_verdict_allows_task_create_for_empty_goal_scope () =
  let obs =
    D.{ base_obs with active_goal_count = 1; unclaimed_task_count = 0 }
  in
  match
    D.legality_verdict obs
      (D.TaskCreate
         {
           title = "Seed goal task";
           description = "Create concrete work for the active goal";
           priority = None;
         })
  with
  | D.Legal -> ()
  | D.Illegal msg -> fail ("expected legal task_create, got: " ^ msg)

let test_legality_verdict_accepts_task_create_without_goal () =
  let obs =
    D.{ base_obs with active_goal_count = 0; unclaimed_task_count = 0 }
  in
  match
    D.legality_verdict obs
      (D.TaskCreate
         {
           title = "Seed goal task";
           description = "Create concrete work for the active goal";
           priority = None;
         })
  with
  | D.Illegal msg -> fail ("model task_create was locally rejected: " ^ msg)
  | D.Legal -> ()

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
        action = TaskClaim { task_id = "task-1"; reason = "urgent" };
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
        action = MultiStep [ MultiStep [] ];
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

let test_delegation_request_from_propose_spawn_action () =
  let request =
    match
      R.of_action ~requester:"planner" ~goal:"ship scheduler hardening"
        (D.ProposeSpawn
           {
             topic = "Audit Slack connector rendering";
             reason = "needs channel-specific formatter work";
           })
    with
    | [ request ] -> request
    | requests ->
        fail
          (Printf.sprintf "expected one delegation request, got %d"
             (List.length requests))
  in
  check string "requester" "planner" request.requester;
  check string "source action" "propose_spawn" request.source_action;
  check string "promotion state" "candidate"
    (R.promotion_state_to_string request.promotion_state);
  check string "task title" "Delegate: Audit Slack connector rendering"
    request.task_seed.title;
  check bool "requester tag" true
    (List.mem "requester:planner" request.task_seed.tags);
  check bool "spawn is not direct" true
    (contains_substring request.task_seed.description
       "not a direct child-agent spawn")

let test_delegation_request_from_execution_result_uses_selected_action () =
  let obs = D.{ base_obs with active_goal_count = 1 } in
  let structured =
    D.
      {
        action =
          ProposeSpawn
            {
              topic = "Review non-dashboard rendering";
              reason = "existing channels lose rich blocks";
            };
        reasoning = "delegate channel-specific work";
        confidence = 0.7;
      }
  in
  let result = D.execute_structured_result obs structured in
  let request =
    match R.of_execution_result ~requester:"rondo" ~goal:"connector parity" result with
    | [ request ] -> request
    | requests ->
        fail
          (Printf.sprintf "expected one delegation request from selected action, got %d"
             (List.length requests))
  in
  let json = R.to_json request in
  check string "schema" "masc.keeper_delegation_request.v1"
    (json_string_field "schema" json);
  check string "json requester" "rondo"
    (json_string_field "requester" json);
  check string "json source action" "propose_spawn"
    (json_string_field "source_action" json);
  match json_field "task_seed" json with
  | Some task_seed ->
      check string "task seed title"
        "Delegate: Review non-dashboard rendering"
        (json_string_field "title" task_seed)
  | None -> fail "expected task_seed"

let test_delegation_request_multistep_projects_all_spawns () =
  let action =
    D.MultiStep
      [
        D.BoardPost { content = "announce intent"; hearth = None };
        D.ProposeSpawn
          { topic = "First delegation"; reason = "primary projection" };
        D.ProposeSpawn
          { topic = "Second delegation"; reason = "also projected" };
      ]
  in
  match R.of_action ~requester:"planner" action with
  | [ first; second ] ->
      check string "first spawn topic" "First delegation" first.topic;
      check string "first spawn reason" "primary projection" first.reason;
      check string "second spawn topic" "Second delegation" second.topic;
      check string "second spawn reason" "also projected" second.reason
  | requests ->
      fail
        (Printf.sprintf "expected two delegation requests, got %d"
           (List.length requests))

let test_delegation_request_json_uses_stable_array_shape () =
  let empty =
    R.delegation_request_json ~requester:"planner" None
    |> json_list_items "empty delegation requests"
  in
  check int "empty request list" 0 (List.length empty);
  let delegation_obs = D.{ base_obs with active_goal_count = 1 } in
  let single_result =
    D.execute_structured_result delegation_obs
      D.
        {
          action =
            ProposeSpawn
              { topic = "Single delegation"; reason = "shape stability" };
          reasoning = "delegate one task";
          confidence = 0.7;
        }
  in
  let single =
    R.delegation_request_json ~requester:"planner" (Some single_result)
    |> json_list_items "single delegation request"
  in
  check int "single request list" 1 (List.length single);
  (match single with
  | [ request_json ] ->
      check string "single schema" "masc.keeper_delegation_request.v1"
        (json_string_field "schema" request_json)
  | _ -> fail "expected one request JSON");
  let multi_result =
    D.execute_structured_result delegation_obs
      D.
        {
          action =
            MultiStep
              [
                ProposeSpawn
                  { topic = "First delegation"; reason = "first" };
                ProposeSpawn
                  { topic = "Second delegation"; reason = "second" };
              ];
          reasoning = "delegate both tasks";
          confidence = 0.8;
        }
  in
  let multiple =
    R.delegation_request_json ~requester:"planner" (Some multi_result)
    |> json_list_items "multiple delegation requests"
  in
  check int "multiple request list" 2 (List.length multiple)

let test_delegation_request_id_includes_goal () =
  let a =
    R.make ~requester:"planner" ~goal:"goal-a" ~topic:"same topic"
      ~reason:"same reason" ()
  in
  let b =
    R.make ~requester:"planner" ~goal:"goal-b" ~topic:"same topic"
      ~reason:"same reason" ()
  in
  check bool "goal changes id" true (not (String.equal a.id b.id))

let test_delegation_request_title_truncates_utf8_boundary () =
  let topic = String.make 79 'a' ^ "\xed\x95\x9c" in
  let request =
    R.make ~requester:"planner" ~topic ~reason:"unicode boundary" ()
  in
  check string "title stops before partial codepoint"
    ("Delegate: " ^ String.make 79 'a')
    request.task_seed.title

let test_delegation_request_store_writes_reviewable_artifacts () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let request =
        R.make ~requester:"planner" ~goal:"connector parity"
          ~topic:"Review non-dashboard rendering"
          ~reason:"existing channels lose rich blocks"
          ()
      in
      let stored =
        match RS.write_request ~base_path:dir request with
        | Ok stored -> stored
        | Error msg -> fail msg
      in
      check bool "request json exists" true (Sys.file_exists stored.json_path);
      check bool "task seed exists" true (Sys.file_exists stored.task_seed_md_path);
      check string "index path" (RS.index_path ~base_path:dir) stored.index_path;
      let json = Yojson.Safe.from_file stored.json_path in
      check string "request schema" "masc.keeper_delegation_request.v1"
        (json_string_field "schema" json);
      let task_seed_md = read_file stored.task_seed_md_path in
      check bool "promotion contract visible" true
        (contains_substring task_seed_md "not a direct child-agent spawn");
      let listing =
        match RS.list_requests ~base_path:dir ~limit:10 with
        | Ok listing -> listing
        | Error msg -> fail msg
      in
      check int "listing total" 1 listing.total;
      match listing.items with
      | [ item ] ->
        check string "listing id" request.id item.id;
        check string "listing requester" "planner" item.requester
      | _ -> fail "expected one delegation request summary")
;;

let test_delegation_request_store_dedups_unchanged_execution () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let obs = D.{ base_obs with active_goal_count = 1 } in
      let execution =
        D.execute_structured_result obs
          D.
            { action =
                ProposeSpawn
                  { topic = "Review connector routing"; reason = "needs owner" }
            ; reasoning = "delegate one task"
            ; confidence = 0.8
            }
      in
      let first =
        match
          RS.write_execution_result ~base_path:dir ~requester:"planner"
            ~goal:"connector parity"
            execution
        with
        | Ok stored -> stored
        | Error msg -> fail msg
      in
      let second =
        match
          RS.write_execution_result ~base_path:dir ~requester:"planner"
            ~goal:"connector parity"
            execution
        with
        | Ok stored -> stored
        | Error msg -> fail msg
      in
      check int "first write" 1 (List.length first);
      check int "second unchanged write" 0 (List.length second);
      let listing =
        match RS.list_requests ~base_path:dir ~limit:10 with
        | Ok listing -> listing
        | Error msg -> fail msg
      in
      check int "deduped listing total" 1 listing.total)
;;

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
        {"action":"task_claim","params":{"task_id":"","reason":"missing task"}},
        {"action":"noop","params":{"reason":"ok"}}
      ]},"reasoning":"bad step","confidence":0.5}|}
  in
  match D.parse_deliberation_response raw with
  | Error _ -> ()
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
  let json_str = {|{"name":"test","initiative_enabled":true,"trace_id":"t1","goal":"g","runtime_id":"local","proactive_enabled":true}|} in
  let json = Yojson.Safe.from_string json_str in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok _ -> fail "initiative_enabled should be rejected"
  | Error e ->
      check bool "removed initiative field mentioned" true
        (String.contains e 'i')

let test_removed_persona_profile_path_rejected () =
  let json_str = {|{"name":"test","persona_profile_path":"config/personas/test/profile.json","trace_id":"t2","goal":"g","runtime_id":"local","proactive_enabled":true}|} in
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

let test_triage_board_new_posts_without_mention () =
  (* Typed Board activity is passed to the model without a local time gate. *)
  let obs =
    { base_obs with
      board_new_post_count = 3;
      board_mention_count = 0;
      idle_seconds = 0;
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

(* ---------- Self-directed legality tests ---------- *)

let test_legality_self_directed_allows_board_post () =
  (* Self-directed context (no goals, long idle) should allow board_post *)
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 1300;
    }
  in
  match D.legality_verdict obs
    (D.BoardPost { content = "Sharing an observation"; hearth = None }) with
  | D.Legal -> ()
  | D.Illegal msg -> fail ("board_post should be legal in self-directed: " ^ msg)

let test_legality_not_self_directed_rejects_board_post () =
  (* Without self-directed context (idle too short), board_post is still illegal *)
  let obs =
    { base_obs with
      active_goal_count = 0;
      idle_seconds = 500;  (* < 300 * 4 = 1200 *)
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
          test_case "failed task is a raw trigger" `Quick
            test_triage_failed_task_is_a_trigger;
          test_case "keeper fiber count change triggers" `Quick
            test_triage_keeper_fiber_count_change;
          test_case "board mention triggers" `Quick
            test_triage_board_mention;
          test_case "multiple triggers" `Quick
            test_triage_multiple_triggers;
        ] );
      ( "actions",
        [
          test_case "noop to policy label" `Quick
            test_action_to_policy_label_noop;
          test_case "board_post to policy label" `Quick
            test_action_to_policy_label_board_post;
          test_case "task_claim to policy label" `Quick
            test_action_to_policy_label_task_claim;
          test_case "task_create to policy label" `Quick
            test_action_to_policy_label_task_create;
          test_case "action to json roundtrip" `Quick
            test_action_to_json_roundtrip;
          test_case "noop to json preserves reason" `Quick
            test_action_to_json_noop;
          test_case "multistep to string" `Quick
            test_action_multistep_to_string;
        ] );
      ( "baseline",
        [
          test_case "mention returns Noop" `Quick
            test_baseline_mention_returns_noop;
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
          test_case "accepts model task_claim" `Quick
            test_legality_verdict_accepts_model_task_claim;
          test_case "allows task_create for empty goal scope" `Quick
            test_legality_verdict_allows_task_create_for_empty_goal_scope;
          test_case "accepts task_create without goal" `Quick
            test_legality_verdict_accepts_task_create_without_goal;
          test_case "rejects nested multi_step" `Quick
            test_legality_verdict_rejects_nested_multistep;
          test_case "keeps legal action" `Quick
            test_execute_structured_result_keeps_legal_action;
          test_case "falls back to baseline" `Quick
            test_execute_structured_result_falls_back_to_baseline;
          test_case "delegation request from propose_spawn action" `Quick
            test_delegation_request_from_propose_spawn_action;
          test_case "delegation request from selected execution" `Quick
            test_delegation_request_from_execution_result_uses_selected_action;
          test_case "delegation request multi_step projects all spawns" `Quick
            test_delegation_request_multistep_projects_all_spawns;
          test_case "delegation request json uses stable array shape" `Quick
            test_delegation_request_json_uses_stable_array_shape;
          test_case "delegation request id includes goal" `Quick
            test_delegation_request_id_includes_goal;
          test_case "delegation request truncates utf8 at boundary" `Quick
            test_delegation_request_title_truncates_utf8_boundary;
          test_case "delegation request store writes reviewable artifacts" `Quick
            test_delegation_request_store_writes_reviewable_artifacts;
          test_case "delegation request store dedups unchanged execution" `Quick
            test_delegation_request_store_dedups_unchanged_execution;
        ] );
      ( "parse_deliberation_response",
        [
          test_case "parse valid noop" `Quick test_parse_valid_noop_json;
          test_case "parse valid task_claim" `Quick
            test_parse_valid_task_claim_json;
          test_case "parse valid task_create" `Quick
            test_parse_valid_task_create_json;
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
      ( "keeper_field_cleanup",
        [
          test_case "initiative field rejected" `Quick
            test_removed_initiative_field_rejected;
          test_case "persona profile path rejected" `Quick
            test_removed_persona_profile_path_rejected;
        ] );
      ( "self_directed_triggers",
        [
          test_case "board new posts without mention" `Quick
            test_triage_board_new_posts_without_mention;
        ] );
      ( "self_directed_legality",
        [
          test_case "self-directed allows board_post" `Quick
            test_legality_self_directed_allows_board_post;
        ] );
    ]
