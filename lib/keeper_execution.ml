(** Keeper_execution — keeper tool execution loop, prompting,
    compaction, proactive/explicit room behavior, and keepalive runtime. *)

open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_exec_tools

include Keeper_coordination
include Keeper_prompt

type social_board_event = {
  kind : [ `Board_post | `Board_comment ];
  post_id : string;
  comment_id : string option;
  author : string;
  content : string;
  created_at : float;
}

type social_turn_outcome = {
  outcome : [ `Acted | `Passed ];
  summary : string;
  reason : string;
  action_kind : string;
  tools_used : string list;
  decision_reason : string option;
  failure_reason : string option;
}

let run_proactive_generation
    ~(specs : Llm_client.model_spec list)
    ~(primary : Llm_client.model_spec)
    ~(config : Room.config)
    ~(ctx_work : Context_manager.working_context)
    ~(meta : keeper_meta)
    ~(continuity_snapshot : keeper_state_snapshot option)
    ~(continuity_summary : string)
    ~(idle_seconds : int) : proactive_generation_result option =
  let base_prompt =
    proactive_prompt_for_keeper ~meta ~idle_seconds continuity_snapshot continuity_summary
  in
  let zero_usage : Llm_client.token_usage =
    { Llm_client.input_tokens = 0; output_tokens = 0; total_tokens = 0;
      cache_creation_input_tokens = 0; cache_read_input_tokens = 0; }
  in
  let max_attempts = 3 in
  let previous_preview = String.trim meta.last_proactive_preview in
  let similarity_threshold = Keeper_config.keeper_proactive_similarity_threshold () in
  let fallback_skill_route =
    route_keeper_skill ~soul_profile:meta.soul_profile ~message:"proactive idle automation checkin"
  in
  let skill_selection_mode = keeper_skill_selection_mode () in
  let base_turn_system_prompt =
    match skill_selection_mode with
    | SkillSelectHeuristic ->
        skill_route_system_prompt_heuristic
          ~base_system_prompt:ctx_work.system_prompt
          ~route:fallback_skill_route
    | SkillSelectAgent ->
        skill_route_system_prompt_agent
          ~base_system_prompt:ctx_work.system_prompt
          ~fallback_route:fallback_skill_route
          ~soul_profile:meta.soul_profile
  in
  let turn_system_prompt =
    append_continuity_context_prompt
      ~base_prompt:base_turn_system_prompt
      continuity_snapshot
      ~continuity_summary
  in
  let max_tool_rounds = 3 in
  let execute_tool_calls
      ~(ctx_work : Context_manager.working_context)
      (tcs : Llm_client.tool_call list) : (Llm_client.tool_call * string) list =
    List.map
      (fun (tc : Llm_client.tool_call) ->
         let output =
           try execute_keeper_tool_call ~config ~meta ~ctx_work tc
           with exn ->
             Yojson.Safe.to_string
               (`Assoc [
                 ("error", `String (Printexc.to_string exn));
                 ("tool", `String tc.call_name);
               ])
         in
         (tc, output))
      tcs
  in
  let run_cascade requests = Llm_client.cascade requests in
  let rec loop attempt usage_acc latency_acc cost_acc retry_hint =
    if attempt > max_attempts then
      Some {
        reply = proactive_fallback_reply ~meta ~idle_seconds;
        usage = usage_acc;
        model_used = primary.model_id;
        latency_ms = latency_acc;
        attempts = max_attempts;
        total_cost_usd = cost_acc;
        fallback_applied = true;
        tools_used = [];
      }
    else
      let prompt =
        if String.trim retry_hint = "" then base_prompt
        else Printf.sprintf "%s\n\n%s" base_prompt retry_hint
      in
      let requests =
        List.map
          (fun (model : Llm_client.model_spec) ->
            ({
               Llm_client.model;
               messages =
                 (Llm_client.system_msg turn_system_prompt)
                 :: (ctx_work.messages @ [ Llm_client.user_msg prompt ]);
               temperature = proactive_temperature attempt;
               max_tokens = Keeper_config.keeper_proactive_max_tokens ();
               tools = keeper_allowed_llm_tools meta;
               response_format = `Text;
             }
              : Llm_client.completion_request))
          specs
      in
      match run_cascade requests with
      | Error _ -> None
      | Ok resp0 ->
          let used_model0 =
            model_spec_for_used specs resp0.model_used
            |> Option.value ~default:primary
          in
          let cost0 = cost_usd_of_usage resp0.usage used_model0 in
          let rec tool_loop ~round ~acc_usage ~acc_latency ~acc_cost
              ~acc_tools_used ~last_resp =
            if last_resp.Llm_client.tool_calls = [] || round > max_tool_rounds then
              let content =
                let c = String.trim last_resp.Llm_client.content in
                if c = "" && acc_tools_used <> [] then
                  Printf.sprintf "(tools executed: %s)"
                    (String.concat ", " acc_tools_used)
                else last_resp.Llm_client.content
              in
              ( content,
                acc_usage,
                last_resp.Llm_client.model_used,
                acc_latency,
                acc_cost,
                acc_tools_used )
            else
              let round_tools =
                List.map
                  (fun (tc : Llm_client.tool_call) -> tc.call_name)
                  last_resp.Llm_client.tool_calls
              in
              let all_tools_so_far = acc_tools_used @ round_tools in
              let tool_outputs =
                execute_tool_calls ~ctx_work last_resp.Llm_client.tool_calls
              in
              let followup_prompt =
                keeper_tool_followup_prompt
                  ~user_message:prompt
                  ~draft_reply:last_resp.Llm_client.content
                  ~tool_outputs
                  ~already_executed:all_tools_so_far
              in
              let write_done =
                keeper_write_done all_tools_so_far
                || List.exists
                     (fun n -> List.mem n [ "keeper_fs_edit"; "keeper_edit" ])
                     all_tools_so_far
              in
              let next_tools =
                keeper_allowed_llm_tools ~write_done meta
              in
              let followup_requests =
                List.map
                  (fun (model : Llm_client.model_spec) ->
                     ({
                        Llm_client.model;
                        messages = [
                          Llm_client.system_msg
                            (keeper_tool_loop_system_prompt
                               ~character_context:turn_system_prompt);
                          Llm_client.user_msg followup_prompt;
                        ];
                        temperature = Keeper_config.keeper_deterministic_temp ();
                        max_tokens = Keeper_config.keeper_proactive_max_tokens ();
                        tools = next_tools;
                        response_format = `Text;
                      }
                       : Llm_client.completion_request))
                  specs
              in
              match run_cascade followup_requests with
              | Error _ ->
                  ( last_resp.Llm_client.content,
                    acc_usage,
                    last_resp.Llm_client.model_used,
                    acc_latency,
                    acc_cost,
                    acc_tools_used @ round_tools )
              | Ok resp_next ->
                  let used_model_next =
                    model_spec_for_used specs resp_next.model_used
                    |> Option.value ~default:primary
                  in
                  let cost_next = cost_usd_of_usage resp_next.usage used_model_next in
                  tool_loop
                    ~round:(round + 1)
                    ~acc_usage:(merge_usage acc_usage resp_next.usage)
                    ~acc_latency:(acc_latency + resp_next.latency_ms)
                    ~acc_cost:(acc_cost +. cost_next)
                    ~acc_tools_used:(acc_tools_used @ round_tools)
                    ~last_resp:resp_next
          in
          let (attempt_content, attempt_usage, attempt_model_used, attempt_latency_ms,
               attempt_cost_usd, attempt_tools_used) =
            tool_loop
              ~round:1
              ~acc_usage:resp0.usage
              ~acc_latency:resp0.latency_ms
              ~acc_cost:cost0
              ~acc_tools_used:[]
              ~last_resp:resp0
          in
          let usage_acc = merge_usage usage_acc attempt_usage in
          let latency_acc = latency_acc + attempt_latency_ms in
          let cost_acc = cost_acc +. attempt_cost_usd in
          let trimmed = String.trim attempt_content in
          if trimmed <> "" then
            (match proactive_quality_check trimmed with
             | Error reason when attempt < max_attempts ->
                 let hint =
                   proactive_retry_instruction (attempt + 1) ~reason
                 in
                 loop (attempt + 1) usage_acc latency_acc cost_acc hint
             | Error _ ->
                 Some {
                   reply = proactive_fallback_reply ~meta ~idle_seconds;
                   usage = usage_acc;
                   model_used = attempt_model_used;
                   latency_ms = latency_acc;
                   attempts = attempt;
                   total_cost_usd = cost_acc;
                   fallback_applied = true;
                   tools_used = attempt_tools_used;
                 }
             | Ok checked_reply ->
                 let too_similar =
                   if previous_preview = "" then false
                   else
                     proactive_similarity_score
                       ~candidate:checked_reply
                       ~previous:previous_preview
                     >= similarity_threshold
                 in
                 if too_similar && attempt < max_attempts then
                   let hint =
                     proactive_retry_instruction (attempt + 1) ~reason:"too_similar"
                   in
                   loop (attempt + 1) usage_acc latency_acc cost_acc hint
                 else
                   Some {
                     reply = checked_reply;
                     usage = usage_acc;
                     model_used = attempt_model_used;
                     latency_ms = latency_acc;
                     attempts = attempt;
                     total_cost_usd = cost_acc;
                     fallback_applied = false;
                     tools_used = attempt_tools_used;
                   })
          else
            let hint =
              proactive_retry_instruction (attempt + 1) ~reason:"empty"
            in
            loop (attempt + 1) usage_acc latency_acc cost_acc hint
  in
  loop 1 zero_usage 0 0.0 ""

let memory_check_default_json () : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool false);
    ("query_kind", `String "none");
    ("expected_topic", `Null);
    ("candidate_count", `Int 0);
    ("initial_score", `Float 0.0);
    ("final_score", `Float 0.0);
    ("threshold", `Float 0.18);
    ("passed", `Bool true);
    ("best_match", `Null);
    ("correction_applied", `Bool false);
    ("correction_success", `Bool false);
    ("prompt_fallback_applied", `Bool false);
    ("prompt_fallback_success", `Bool false);
    ("deterministic_fallback_applied", `Bool false);
    ("recall_fallback_applied", `Bool false);
  ]

(** Check if keeper autonomy engine is enabled via environment variable. *)
let keeper_autonomy_enabled () =
  match Sys.getenv_opt "MASC_KEEPER_AUTONOMY_ENABLED" with
  | Some s -> String.lowercase_ascii (String.trim s) = "true"
  | None -> false

(* ================================================================ *)
(* Autonomous Execution Engine (Phase 5)                            *)
(* ================================================================ *)

(** Gate config for autonomous keeper execution.
    Restricts allowed tools to safe, read-only + board operations.
    @since 2.74.0 *)
let autonomous_gate_config
    ~(autonomy_level : Keeper_autonomy.autonomy_level) : Eval_gate.gate_config =
  let base_allowed = [
    "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote"; "keeper_board_list";
    "keeper_read"; "keeper_fs_read";
    "keeper_memory_search";
    "keeper_time_now"; "keeper_context_status";
  ] in
  let base_denied = [
    "keeper_bash"; "keeper_edit"; "keeper_fs_edit"; "keeper_github";
  ] in
  match autonomy_level with
  | L4_Autonomous ->
      (* L4: allow bash for safe commands *)
      {
        max_cost_usd = Keeper_config.keeper_cost_gate_usd ();
        max_tool_calls_per_turn = 5;
        entropy_threshold = 2;
        destructive_check_enabled = true;
        allowlist_enabled = true;
        allowed_tools = "keeper_bash" :: base_allowed;
        denied_tools = List.filter (fun t -> t <> "keeper_bash") base_denied;
      }
  | L5_Independent ->
      (* L5: all tools allowed, higher budget *)
      {
        max_cost_usd = Keeper_config.keeper_tool_cost_max_usd ();
        max_tool_calls_per_turn = 10;
        entropy_threshold = 3;
        destructive_check_enabled = true;
        allowlist_enabled = false;
        allowed_tools = [];
        denied_tools = [];
      }
  | _ ->
      (* L3 and below: strict safe-only *)
      {
        max_cost_usd = Keeper_config.keeper_cost_gate_usd ();
        max_tool_calls_per_turn = 5;
        entropy_threshold = 2;
        destructive_check_enabled = true;
        allowlist_enabled = true;
        allowed_tools = base_allowed;
        denied_tools = base_denied;
      }

(** Execute an approved/cautioned action plan via LLM + tool loop with gate sandboxing.

    1. Inject plan text into LLM system prompt
    2. LLM generates tool_calls based on plan
    3. Each tool_call goes through Eval_gate.guarded_execute
    4. Recursive tool_loop (max 3 rounds)
    5. Returns execution summary

    @since 2.74.0 *)
let execute_approved_plan
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(specs : Llm_client.model_spec list)
    ~(plan : string)
    ~(pa : Keeper_autonomy.proposed_action)
    ~(autonomy_level : Keeper_autonomy.autonomy_level)
    ~(trajectory_acc : Trajectory.accumulator option)
    : string * float * string list =
  let gate_config = autonomous_gate_config ~autonomy_level in
  let primary = match specs with p :: _ -> p | [] -> Llm_client.default_local_model_spec () in
  let system_prompt = Printf.sprintf
{|You are a keeper agent executing an approved action plan.
Your name: %s
Goal: %s (id=%s)

Approved Plan:
%s

Execute step 1 of this plan using the available tools.
Be concise. Only use tools that directly advance the plan.
Do NOT use destructive tools (bash rm, edit, delete).|}
    meta.name pa.goal_title pa.goal_id plan
  in
  let ctx_work = Context_manager.create
    ~system_prompt:(Printf.sprintf "Keeper %s autonomous execution" meta.name)
    ~max_tokens:4000 in
  let execute_tool_calls
      (tcs : Llm_client.tool_call list) : (Llm_client.tool_call * string) list =
    List.map
      (fun (tc : Llm_client.tool_call) ->
         let execute () =
           execute_keeper_tool_call ~config ~meta ~ctx_work tc
         in
         let (decision, result_opt, _post_eval, duration_ms) =
           Eval_gate.guarded_execute
             ~config:gate_config
             ~accumulated_cost:0.0
             ~trajectory_acc
             ~tool_name:tc.call_name
             ~args_json:tc.call_arguments
             ~execute
         in
         let result = match decision, result_opt with
           | Trajectory.Reject reason, _ ->
               Log.Keeper.error "autonomy GATE BLOCKED %s: %s"
                 tc.call_name reason;
               Yojson.Safe.to_string (`Assoc [("gate_blocked", `String tc.call_name); ("reason", `String reason)])
           | _, Some r -> r
           | _, None -> "{\"error\":\"no result\"}"
         in
         (* Record to trajectory *)
         (match trajectory_acc with
          | Some acc ->
              Trajectory.record_entry acc {
                ts = Time_compat.now ();
                ts_iso = Types.now_iso ();
                turn = acc.Trajectory.turn;
                round = 0;
                tool_name = tc.call_name;
                args_json = tc.call_arguments;
                gate_decision = decision;
                result = Some (if String.length result > 500
                          then String.sub result 0 500 ^ "..."
                          else result);
                duration_ms;
                error = None;
                cost_usd = 0.0;
              }
          | None -> ());
         (tc, result))
      tcs
  in
  let run_cascade requests = Llm_client.cascade requests in
  let max_rounds = 3 in
  let initial_request =
    { Llm_client.model = primary;
      messages = [
        Llm_client.system_msg system_prompt;
        Llm_client.user_msg "Execute the first step of the plan now.";
      ];
      temperature = Keeper_config.keeper_deterministic_temp ();
      max_tokens = Keeper_config.keeper_proactive_max_tokens ();
      tools = keeper_allowed_llm_tools meta;
      response_format = `Text;
    }
  in
  let requests = List.map (fun (spec : Llm_client.model_spec) ->
    { initial_request with Llm_client.model = spec }
  ) specs in
  match run_cascade requests with
  | Error e ->
      (Printf.sprintf "LLM cascade failed: %s" e, 0.0, [])
  | Ok resp0 ->
      let rec exec_loop ~round ~acc_cost ~acc_tools ~last_resp =
        if last_resp.Llm_client.tool_calls = [] || round > max_rounds then
          let content =
            let c = String.trim last_resp.Llm_client.content in
            if c = "" && acc_tools <> [] then
              Printf.sprintf "(autonomous execution: %s)"
                (String.concat ", " acc_tools)
            else c
          in
          (content, acc_cost, acc_tools)
        else
          let round_tools =
            List.map (fun (tc : Llm_client.tool_call) -> tc.call_name)
              last_resp.Llm_client.tool_calls
          in
          let all_tools = acc_tools @ round_tools in
          let tool_outputs = execute_tool_calls last_resp.Llm_client.tool_calls in
          let followup_prompt =
            keeper_tool_followup_prompt
              ~user_message:"Execute the next step of the plan."
              ~draft_reply:last_resp.Llm_client.content
              ~tool_outputs
              ~already_executed:all_tools
          in
          (* Stop providing tools after write operations *)
          let write_done =
            keeper_write_done all_tools
          in
          let next_tools = keeper_allowed_llm_tools ~write_done meta in
          let followup_requests = List.map (fun (spec : Llm_client.model_spec) ->
            { Llm_client.model = spec;
              messages = [
                Llm_client.system_msg system_prompt;
                Llm_client.user_msg followup_prompt;
              ];
              temperature = Keeper_config.keeper_deterministic_temp ();
              max_tokens = Keeper_config.keeper_proactive_max_tokens ();
              tools = next_tools;
              response_format = `Text;
            }
          ) specs in
          match run_cascade followup_requests with
          | Error _ ->
              (last_resp.Llm_client.content, acc_cost, all_tools)
          | Ok next_resp ->
              let used_spec =
                model_spec_for_used specs next_resp.model_used
                |> Option.value ~default:primary
              in
              let round_cost = cost_usd_of_usage next_resp.usage used_spec in
              exec_loop ~round:(round + 1)
                ~acc_cost:(acc_cost +. round_cost)
                ~acc_tools:all_tools
                ~last_resp:next_resp
      in
      let used_spec0 =
        model_spec_for_used specs resp0.model_used
        |> Option.value ~default:primary
      in
      let cost0 = cost_usd_of_usage resp0.usage used_spec0 in
      exec_loop ~round:1 ~acc_cost:cost0 ~acc_tools:[] ~last_resp:resp0

(** Autonomous goal turn: evaluate goals and optionally generate/verify action plan.
    Returns Some updated_meta when an autonomous action decision was made,
    None to fall through to regular proactive generation.
    @since 2.74.0 *)
let run_autonomous_goal_turn ~(config : Room.config) ~(meta : keeper_meta)
    ~(specs : Llm_client.model_spec list) : keeper_meta option =
  if not (keeper_autonomy_enabled ()) then None
  else if meta.active_goal_ids = [] then None
  else
    match Keeper_contract.parse_autonomy_level meta.autonomy_level with
    | None -> None
    | Some L1_Reactive -> None
    | Some level ->
        let primary = match specs with p :: _ -> p | [] -> Llm_client.default_local_model_spec () in
        let verify_model =
          match Llm_client.default_verifier_model_spec () with
          | Ok model -> model
          | Error _ -> primary
        in
        let keeper_context =
          Printf.sprintf "keeper=%s autonomy=%s turns=%d cost=$%.4f"
            meta.name (Keeper_autonomy.autonomy_level_to_string level)
            meta.total_turns meta.total_cost_usd
        in
        match level with
        | L1_Reactive -> None
        | L2_Suggestive ->
            (* L2: evaluate and post suggestion to Board *)
            let next = Keeper_autonomy.evaluate_next_action
              ~config ~goal_ids:meta.active_goal_ids ~keeper_name:meta.name in
            (match next with
             | Propose pa ->
                 Log.Keeper.info "autonomy %s L2 suggest: %s (risk=%s, cost=$%.2f)"
                   meta.name pa.action_description
                   (Keeper_autonomy.risk_level_to_string pa.risk_level)
                   pa.estimated_cost_usd;
                 let board_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L2 제안] %s" pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**제안 액션**: %s\n\n- Risk: %s\n- Estimated cost: $%.2f\n- Goal: %s (id=%s)"
                     pa.action_description
                     (Keeper_autonomy.risk_level_to_string pa.risk_level)
                     pa.estimated_cost_usd
                     pa.goal_title pa.goal_id));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "L2-suggestion";
                     `String meta.name;
                   ]);
                 ] in
                 let board_args =
                   ensure_keeper_board_post_args ~author:meta.name
                     ~source:"keeper_autonomy_suggestion" board_args
                 in
                 let (ok, _msg) = Tool_board.handle_tool "masc_board_post" board_args in
                 if not ok then
                   Log.Keeper.error "autonomy %s L2 board post failed" meta.name;
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   updated_at = now_iso ();
                 }
             | StartPerpetualAgent req ->
                 Log.Keeper.info "autonomy %s L2 perpetual suggest: %s"
                   meta.name req.goal_title;
                 let board_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L2 제안] Perpetual Agent: %s" req.goal_title));
                   ("content", `String (Printf.sprintf
                     "**장기 목표 감지**: %s\n\n이 목표는 Perpetual Agent가 적합합니다.\n- Models: %s\n- Coding mode: %b\n- Agent: %s\n\nL3+ 자율성에서 자동 시작됩니다."
                     req.goal_title
                     (String.concat ", " req.models)
                     req.coding_mode
                     req.coding_agent));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "perpetual-suggestion";
                     `String meta.name;
                   ]);
                 ] in
                 let board_args =
                   ensure_keeper_board_post_args ~author:meta.name
                     ~source:"keeper_autonomy_perpetual_suggestion" board_args
                 in
                 (match Tool_board.handle_tool "masc_board_post" board_args with
                  | (true, _) -> ()
                  | (false, err) ->
                      Log.Keeper.error "autonomy %s L2 perpetual board post failed: %s" meta.name err
                  | exception exn ->
                      log_keeper_exn ~label:(Printf.sprintf "autonomy %s L2 board post error" meta.name) exn);
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   updated_at = now_iso ();
                 }
             | _ -> None)
        | _ ->
            (* L3+: full pipeline — evaluate, plan, verify, decide *)
            let result = Keeper_verifier.run_pipeline
              ~config
              ~goal_ids:meta.active_goal_ids
              ~keeper_name:meta.name
              ~keeper_context
              ~plan_model:primary
              ~verify_model
              ~autonomy_level:level
            in
            (match result with
             | NothingToDo reason ->
                 Log.Keeper.info "autonomy %s: nothing to do (%s)" meta.name reason;
                 None
             | PerpetualRequested req ->
                 Log.Keeper.info "autonomy %s PERPETUAL: starting for %s"
                   meta.name req.goal_title;
                 (* Keeper runs in heartbeat timer context without Eio.Switch.t,
                    so coding_mode (= Claude Code spawn) is structurally unavailable.
                    Force LLM-only mode to prevent guaranteed failure. *)
                 let effective_coding_mode = false in
                 (if req.coding_mode then
                    Log.Keeper.warn "autonomy %s: coding_mode requested but unavailable (no Eio.Switch in heartbeat context), falling back to LLM-only" meta.name);
                 let perp_args = `Assoc [
                   ("goal", `String req.goal_title);
                   ("models", `List (List.map (fun m -> `String m) req.models));
                   ("coding_mode", `Bool effective_coding_mode);
                   ("coding_agent", `String req.coding_agent);
                 ] in
                 let perp_ctx = {
                   Tool_perpetual.agent_name = meta.name;
                   start_loop = None;
                   sw = None;
                   proc_mgr = None;
                   room_config = None;
                 } in
                 (match Tool_perpetual.dispatch perp_ctx ~name:"masc_perpetual_start" ~args:perp_args with
                  | Some (true, result_json) ->
                      Log.Keeper.info "autonomy %s perpetual started: %s"
                        meta.name result_json;
                      (* Update goal with perpetual agent info *)
                      (try ignore (Goal_store.review_goal config
                        ~goal_id:req.goal_id ~outcome:"progress"
                        ~note:(Printf.sprintf "Perpetual agent started (models: %s)"
                          (String.concat ", " req.models)) ()) with exn ->
                        log_keeper_exn ~label:"goal review failed" exn);
                      (* Post to Board *)
                      let board_args = `Assoc [
                        ("author", `String meta.name);
                        ("title", `String (Printf.sprintf "[L%d Perpetual] %s"
                          (Keeper_autonomy.autonomy_level_to_int level) req.goal_title));
                        ("content", `String (Printf.sprintf
                          "Perpetual Agent started for long-horizon goal.\n\n- Goal: %s (id=%s)\n- Models: %s\n- Coding mode: %b"
                          req.goal_title req.goal_id
                          (String.concat ", " req.models) req.coding_mode));
                        ("tags", `List [
                          `String "keeper-autonomy";
                          `String "perpetual-start";
                          `String meta.name;
                        ]);
                      ] in
                      let board_args =
                        ensure_keeper_board_post_args ~author:meta.name
                          ~source:"keeper_autonomy_perpetual_start" board_args
                      in
                      (match Tool_board.handle_tool "masc_board_post" board_args with
                       | (true, _) -> ()
                       | (false, err) ->
                           Log.Keeper.error "autonomy %s: board post failed: %s" meta.name err
                       | exception exn ->
                           log_keeper_exn ~label:(Printf.sprintf "autonomy %s board post error" meta.name) exn);
                      Some { meta with
                        last_autonomous_action_at = now_iso ();
                        autonomous_action_count = meta.autonomous_action_count + 1;
                        updated_at = now_iso ();
                      }
                  | Some (false, err) ->
                      Log.Keeper.error "autonomy %s perpetual start failed: %s"
                        meta.name err;
                      None
                  | None ->
                      Log.Keeper.error "autonomy %s perpetual dispatch returned None" meta.name;
                      None)
             | Approved (pa, plan) ->
                 Log.Keeper.info "autonomy %s APPROVED: %s"
                   meta.name pa.action_description;
                 (* 5-3: Create trajectory accumulator for this autonomous turn *)
                 let masc_root = Filename.concat config.base_path ".masc" in
                 let traj_acc = Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Printf.sprintf "keeper-auto-%s-%d"
                     meta.name meta.autonomous_action_count)
                   ~generation:meta.generation in
                 (* 5-4: SSE — keeper_autonomy_start *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_start");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("action", `String pa.action_description);
                   ("autonomy_level", `String (Keeper_autonomy.autonomy_level_to_string level));
                 ]) with exn ->
                   log_keeper_exn ~label:"SSE keeper_autonomy_start broadcast failed" exn);
                 (* 5-2: Execute the approved plan *)
                 let (summary, exec_cost, tools_used) =
                   execute_approved_plan ~config ~meta ~specs ~plan ~pa
                     ~autonomy_level:level ~trajectory_acc:(Some traj_acc) in
                 (* 5-3: Finalize trajectory *)
                 (try ignore (Trajectory.finalize traj_acc Trajectory.Completed)
                  with exn -> log_keeper_exn ~label:"trajectory finalize failed" exn);
                 (* 5-3: Update goal progress *)
                 let outcome = if tools_used <> [] then "progress" else "blocked" in
                 let review_note = Printf.sprintf
                   "Autonomous execution (L%d): %s | tools: [%s] | cost: $%.4f"
                   (Keeper_autonomy.autonomy_level_to_int level)
                   (if String.length summary > 200 then String.sub summary 0 200 ^ "..." else summary)
                   (String.concat ", " tools_used)
                   exec_cost in
                 (try ignore (Goal_store.review_goal config
                   ~goal_id:pa.goal_id ~outcome ~note:review_note ()) with exn ->
                   log_keeper_exn ~label:"goal review failed" exn);
                 (* 5-4: Post execution report to Board *)
                 let report_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L%d 실행] %s"
                     (Keeper_autonomy.autonomy_level_to_int level) pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**실행 결과**: %s\n\n- Tools used: [%s]\n- Cost: $%.4f\n- Goal: %s (id=%s)\n- Outcome: %s"
                     (if String.length summary > 500 then String.sub summary 0 500 ^ "..." else summary)
                     (String.concat ", " tools_used) exec_cost
                     pa.goal_title pa.goal_id outcome));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "execution-report";
                     `String meta.name;
                   ]);
                 ] in
                 let report_args =
                   ensure_keeper_board_post_args ~author:meta.name
                     ~source:"keeper_autonomy_execution_report" report_args
                 in
                 let (_ok, _msg) = Tool_board.handle_tool "masc_board_post" report_args in
                 (* 5-4: SSE — keeper_autonomy_complete *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_complete");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("result", `String outcome);
                   ("tools_used", `List (List.map (fun t -> `String t) tools_used));
                   ("cost_usd", `Float exec_cost);
                 ]) with exn ->
                   log_keeper_exn ~label:"SSE keeper_autonomy_complete broadcast failed" exn);
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   total_cost_usd = meta.total_cost_usd +. exec_cost;
                   updated_at = now_iso ();
                 }
             | Cautioned (pa, plan, warning) ->
                 Log.Keeper.warn "autonomy %s CAUTIONED: %s (warning: %s)"
                   meta.name pa.action_description warning;
                 (* 5-3: Trajectory with warning recorded *)
                 let masc_root = Filename.concat config.base_path ".masc" in
                 let traj_acc = Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Printf.sprintf "keeper-auto-%s-%d-cautioned"
                     meta.name meta.autonomous_action_count)
                   ~generation:meta.generation in
                 (* Record caution warning to trajectory *)
                 Trajectory.record_entry traj_acc {
                   ts = Time_compat.now ();
                   ts_iso = Types.now_iso ();
                   turn = traj_acc.Trajectory.turn;
                   round = 0;
                   tool_name = "_caution_warning";
                   args_json = Yojson.Safe.to_string (`Assoc [("warning", `String warning)]);
                   gate_decision = Trajectory.Pass;
                   result = Some warning;
                   duration_ms = 0;
                   error = None;
                   cost_usd = 0.0;
                 };
                 (* 5-4: SSE — keeper_autonomy_start (cautioned) *)
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_start");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("action", `String pa.action_description);
                   ("autonomy_level", `String (Keeper_autonomy.autonomy_level_to_string level));
                   ("caution", `String warning);
                 ]) with exn ->
                   log_keeper_exn ~label:"SSE keeper_autonomy_start (cautioned) broadcast failed" exn);
                 (* 5-2: Execute despite caution *)
                 let (summary, exec_cost, tools_used) =
                   execute_approved_plan ~config ~meta ~specs ~plan ~pa
                     ~autonomy_level:level ~trajectory_acc:(Some traj_acc) in
                 (try ignore (Trajectory.finalize traj_acc Trajectory.Completed)
                  with exn -> log_keeper_exn ~label:"trajectory finalize (cautioned) failed" exn);
                 (* 5-3: Update goal progress *)
                 let outcome = if tools_used <> [] then "progress" else "blocked" in
                 let review_note = Printf.sprintf
                   "Cautioned execution (L%d, warning: %s): %s | tools: [%s] | cost: $%.4f"
                   (Keeper_autonomy.autonomy_level_to_int level) warning
                   (if String.length summary > 150 then String.sub summary 0 150 ^ "..." else summary)
                   (String.concat ", " tools_used)
                   exec_cost in
                 (try ignore (Goal_store.review_goal config
                   ~goal_id:pa.goal_id ~outcome ~note:review_note ()) with exn ->
                   log_keeper_exn ~label:"goal review (cautioned) failed" exn);
                 (* 5-4: Board report + SSE complete *)
                 let report_args = `Assoc [
                   ("author", `String meta.name);
                   ("title", `String (Printf.sprintf "[L%d 실행⚠] %s"
                     (Keeper_autonomy.autonomy_level_to_int level) pa.goal_title));
                   ("content", `String (Printf.sprintf
                     "**경고**: %s\n\n**실행 결과**: %s\n\n- Tools: [%s]\n- Cost: $%.4f\n- Goal: %s (id=%s)"
                     warning
                     (if String.length summary > 400 then String.sub summary 0 400 ^ "..." else summary)
                     (String.concat ", " tools_used) exec_cost
                     pa.goal_title pa.goal_id));
                   ("tags", `List [
                     `String "keeper-autonomy";
                     `String "execution-report";
                     `String "cautioned";
                     `String meta.name;
                   ]);
                 ] in
                 let report_args =
                   ensure_keeper_board_post_args ~author:meta.name
                     ~source:"keeper_autonomy_cautioned_report" report_args
                 in
                 let (_ok, _msg) = Tool_board.handle_tool "masc_board_post" report_args in
                 (try Sse.broadcast (`Assoc [
                   ("type", `String "keeper_autonomy_complete");
                   ("name", `String meta.name);
                   ("goal_id", `String pa.goal_id);
                   ("result", `String outcome);
                   ("tools_used", `List (List.map (fun t -> `String t) tools_used));
                   ("cost_usd", `Float exec_cost);
                   ("warning", `String warning);
                 ]) with exn ->
                   log_keeper_exn ~label:"SSE keeper_autonomy_complete (cautioned) broadcast failed" exn);
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   total_cost_usd = meta.total_cost_usd +. exec_cost;
                   updated_at = now_iso ();
                 }
             | Rejected (pa, reason) ->
                 Log.Keeper.info "autonomy %s REJECTED: %s (%s)"
                   meta.name pa.action_description reason;
                 None)

let maybe_emit_proactive (ctx : _ context) (meta : keeper_meta) : keeper_meta =
  let log_proactive_failure reason =
    Log.Keeper.error "proactive emission failed: %s" reason
  in
  if not meta.proactive_enabled then meta
  else if Agent_economy.economic_pressure
            ~base_path:ctx.config.base_path ~agent_name:meta.name
          = Agent_economy.Hustle then begin
    Log.Keeper.info "economy hustle mode: suppressing proactive for %s" meta.name;
    meta  (* Skip proactive entirely in Hustle mode *)
  end
  else
    let now_ts = Time_compat.now () in
    let created_ts =
      Resilience.Time.parse_iso8601_opt meta.created_at |> Option.value ~default:0.0
    in
    let activity_ts =
      let base = max meta.last_turn_ts meta.last_proactive_ts in
      if base > 0.0 then base else created_ts
    in
    let idle_seconds =
      if activity_ts <= 0.0 then 0 else int_of_float (max 0.0 (now_ts -. activity_ts))
    in
    let idle_gate = normalize_proactive_idle_sec meta.proactive_idle_sec in
    (* Agent Economy: Frugal mode doubles cooldown *)
    let frugal_cooldown_multiplier =
      if Agent_economy.economic_pressure
           ~base_path:ctx.config.base_path ~agent_name:meta.name
         = Agent_economy.Frugal then 2 else 1
    in
    let cooldown_gate =
      frugal_cooldown_multiplier * normalize_proactive_cooldown_sec meta.proactive_cooldown_sec in
    let cooldown_elapsed =
      if meta.last_proactive_ts <= 0.0 then max_int
      else int_of_float (max 0.0 (now_ts -. meta.last_proactive_ts))
    in
    if idle_seconds < idle_gate || cooldown_elapsed < cooldown_gate then meta
    else
      (* Phase 2 Deliberation Engine: if policy_mode is Llm_deliberation AND
         triage returned Triggered, call the LLM deliberation engine instead
         of the existing proactive logic. *)
      let policy_mode =
        Keeper_contract.policy_mode_of_string meta.policy_mode
      in
      let triage_is_triggered =
        Keeper_contract.policy_mode_is_deliberation policy_mode
        && (let tt = String.trim meta.last_triage_triggers in
            tt <> "" && not (String.length tt >= 5
                            && String.sub tt 0 5 = "skip:"))
      in
      if triage_is_triggered then (
        (* Deliberation engine path *)
        let daily_budget = Keeper_deliberation.daily_budget_usd_from_env () in
        if not (Keeper_deliberation.deliberation_budget_check
                  ~daily_budget_usd:daily_budget
                  ~cost_today_usd:meta.deliberation_cost_total_usd)
        then (
          Log.Keeper.warn "deliberation %s budget exhausted (%.4f >= %.4f)"
            meta.name meta.deliberation_cost_total_usd daily_budget;
          meta)
        else
          match model_specs_of_strings meta.models with
          | Error msg ->
              log_proactive_failure
                ("deliberation model specs: " ^ msg);
              meta
          | Ok specs -> (
              match ensure_api_keys specs with
              | Error msg ->
                  log_proactive_failure
                    ("deliberation api keys: " ^ msg);
                  meta
              | Ok () ->
                  (* Parse triggers from last_triage_triggers string *)
                  let trigger_strs =
                    String.split_on_char ',' meta.last_triage_triggers
                    |> List.map String.trim
                    |> List.filter (fun s -> s <> "")
                  in
                  let triggers =
                    List.filter_map (fun s ->
                      match s with
                      | "direct_mention" ->
                          Some Keeper_deliberation.DirectMention
                      | "new_unclaimed_task" ->
                          Some Keeper_deliberation.NewUnclaimedTask
                      | "failed_task" ->
                          Some Keeper_deliberation.FailedTask
                      | "agent_joined_or_left" ->
                          Some Keeper_deliberation.AgentJoinedOrLeft
                      | "goal_deadline" ->
                          Some Keeper_deliberation.GoalDeadline
                      | "idle_timeout" ->
                          Some Keeper_deliberation.IdleTimeout
                      | "strategic_review" ->
                          Some Keeper_deliberation.StrategicReview
                      | other ->
                          if String.length other > 15
                             && String.sub other 0 15 = "board_activity:" then
                            Some (Keeper_deliberation.BoardActivity
                                    (String.sub other 15
                                       (String.length other - 15)))
                          else if String.length other > 17
                                  && String.sub other 0 17 = "metrics_anomaly:" then
                            Some (Keeper_deliberation.MetricsAnomaly
                                    (String.sub other 17
                                       (String.length other - 17)))
                          else None)
                      trigger_strs
                  in
                  if triggers = [] then (
                    Log.Keeper.warn "deliberation %s no parseable triggers from: %s"
                      meta.name meta.last_triage_triggers;
                    meta)
                  else
                    (* Build world observation for prompt with L2 room enrichment *)
                    let unclaimed_count, failed_count =
                      (try
                         let backlog = Room.read_backlog ctx.config in
                         let unclaimed =
                           List.length
                             (List.filter
                                (fun (t : Types.task) ->
                                  t.task_status = Types.Todo)
                                backlog.tasks)
                         in
                         let failed =
                           List.length
                             (List.filter
                                (fun (t : Types.task) ->
                                  match t.task_status with
                                  | Types.Cancelled _ -> true
                                  | _ -> false)
                                backlog.tasks)
                         in
                         (unclaimed, failed)
                       with exn ->
                         Log.Keeper.warn "execution: task count query failed: %s" (Printexc.to_string exn);
                         (0, 0))
                    in
                    let active_agents =
                      (try List.length (Room.get_agents_raw ctx.config)
                       with exn ->
                         Log.Keeper.warn "execution: agent count query failed: %s" (Printexc.to_string exn);
                         0)
                    in
                    let obs =
                      { (Keeper_deliberation.empty_world_observation
                           ~keeper_name:meta.name)
                        with
                        unclaimed_task_count = unclaimed_count;
                        failed_task_count = failed_count;
                        active_agent_count = active_agents;
                        active_goal_count =
                          List.length meta.active_goal_ids;
                        idle_seconds;
                        idle_gate;
                        direct_mention =
                          List.mem Keeper_deliberation.DirectMention
                            triggers;
                      }
                    in
                    let prompt =
                      Keeper_deliberation.build_deliberation_prompt
                        ~autonomy_level:meta.autonomy_level
                        ~keeper_name:meta.name
                        ~soul_profile:meta.soul_profile
                        ~goal:meta.goal
                        ~triggers
                        obs
                    in
                    let model_specs =
                      Llm_client.available_model_specs_of_strings meta.models
                    in
                    let result =
                      Llm_client.run_prompt_cascade
                        ~temperature:0.3
                        ~model_specs
                        ~max_tokens:1024
                        ~prompt
                        ~system:("You are " ^ meta.name
                                 ^ ", a keeper agent. Respond with JSON only.")
                        ()
                    in
                    match result with
                    | Error msg ->
                        Log.Keeper.error "deliberation %s LLM call failed: %s"
                          meta.name msg;
                        meta
                    | Ok response ->
                        let turn_cost =
                          let inp =
                            float_of_int response.usage.input_tokens /. 1000.0
                          in
                          let outp =
                            float_of_int response.usage.output_tokens /. 1000.0
                          in
                          let primary =
                            match model_specs with
                            | p :: _ -> p
                            | [] -> Llm_client.default_local_model_spec ()
                          in
                          (inp *. primary.cost_per_1k_input)
                          +. (outp *. primary.cost_per_1k_output)
                        in
                        (match
                           Keeper_deliberation.parse_deliberation_response
                             response.content
                         with
                         | Error msg ->
                             Log.Keeper.error "deliberation %s parse failed: %s (raw: %s)"
                               meta.name msg
                               (Keeper_types.short_preview response.content);
                             (* Update meta with cost even on parse failure *)
                             let updated =
                               { meta with
                                 deliberation_count =
                                   meta.deliberation_count + 1;
                                 deliberation_cost_total_usd =
                                   meta.deliberation_cost_total_usd
                                   +. turn_cost;
                                 last_deliberation_ts = now_ts;
                                 updated_at = now_iso ();
                               }
                             in
                             (match write_meta ctx.config updated with
                              | Ok () -> ()
                              | Error msg ->
                                  Log.Keeper.error "deliberation write_meta failed: %s"
                                    msg);
                             updated
                         | Ok (action, reasoning, confidence) ->
                             Log.Keeper.info "deliberation %s decided: %s (confidence=%.2f, reason=%s)"
                               meta.name
                               (Keeper_deliberation.deliberation_action_to_string action)
                               confidence
                               (Keeper_types.short_preview reasoning);
                             (* Execute the action *)
                             (match action with
                              | Keeper_deliberation.Noop _reason -> ()
                              | Keeper_deliberation.ReplyInRoom { room_id; content } ->
                                  let target_room =
                                    if room_id = "" || room_id = "default"
                                    then Room.current_room_id ctx.config
                                    else room_id
                                  in
                                  (try
                                     ignore
                                       (Room.broadcast_in_room ctx.config
                                          ~room_id:target_room
                                          ~from_agent:meta.agent_name
                                          ~content)
                                   with exn ->
                                     log_keeper_exn ~label:"deliberation reply_in_room failed" exn)
                              | Keeper_deliberation.Broadcast { message } ->
                                  (try
                                     ignore
                                       (Room.broadcast ctx.config
                                          ~from_agent:meta.agent_name
                                          ~content:message)
                                   with exn ->
                                     log_keeper_exn ~label:"deliberation broadcast failed" exn)
                              | Keeper_deliberation.TaskClaim { task_id; reason = _ } ->
                                  (try
                                     let result =
                                       Room.claim_task ctx.config
                                         ~agent_name:meta.agent_name
                                         ~task_id
                                     in
                                     Log.Keeper.info "deliberation task_claim result: %s"
                                       result
                                   with exn ->
                                     log_keeper_exn ~label:"deliberation task_claim failed" exn)
                              | Keeper_deliberation.BoardPost { content; hearth } ->
                                  (try
                                     ignore
                                       (Board_dispatch.create_post
                                          ~author:meta.agent_name
                                          ~content
                                          ?hearth
                                          ())
                                   with exn ->
                                     log_keeper_exn ~label:"deliberation board_post failed" exn)
                              | Keeper_deliberation.BoardComment { post_id; content } ->
                                  (try
                                     ignore
                                       (Board_dispatch.add_comment
                                          ~post_id
                                          ~author:meta.agent_name
                                          ~content
                                          ())
                                   with exn ->
                                     log_keeper_exn ~label:"deliberation board_comment failed" exn)
                              | Keeper_deliberation.BoardVote { post_id; direction } ->
                                  (try
                                     let dir : Board.vote_direction =
                                       if String.lowercase_ascii direction = "down"
                                       then Board.Down
                                       else Board.Up
                                     in
                                     ignore
                                       (Board_dispatch.vote
                                          ~voter:meta.agent_name
                                          ~post_id
                                          ~direction:dir)
                                   with exn ->
                                     log_keeper_exn ~label:"deliberation board_vote failed" exn)
                              | Keeper_deliberation.ProposeSpawn { topic; reason } ->
                                  (try
                                     let msg =
                                       Printf.sprintf
                                         "[spawn-proposal] %s proposes spawning agent for topic '%s': %s"
                                         meta.name topic reason
                                     in
                                     ignore
                                       (Room.broadcast ctx.config
                                          ~from_agent:meta.agent_name
                                          ~content:msg)
                                   with exn ->
                                     log_keeper_exn ~label:"deliberation propose_spawn failed" exn)
                              | Keeper_deliberation.MultiStep actions ->
                                  let max_steps = 5 in
                                  let steps_to_run =
                                    if List.length actions > max_steps then
                                      let rec take n acc = function
                                        | _ when n <= 0 -> List.rev acc
                                        | [] -> List.rev acc
                                        | x :: xs -> take (n - 1) (x :: acc) xs
                                      in
                                      take max_steps [] actions
                                    else actions
                                  in
                                  let step_count = ref 0 in
                                  let stop = ref false in
                                  List.iter
                                    (fun step_action ->
                                      if !stop then ()
                                      else (
                                        incr step_count;
                                        Log.Keeper.info "deliberation %s multi_step %d/%d: %s"
                                          meta.name !step_count (List.length steps_to_run)
                                          (Keeper_deliberation.deliberation_action_to_string
                                             step_action);
                                        (try
                                           match step_action with
                                           | Keeper_deliberation.Noop _ -> ()
                                           | Keeper_deliberation.ReplyInRoom { room_id; content } ->
                                               let target_room =
                                                 if room_id = "" || room_id = "default"
                                                 then Room.current_room_id ctx.config
                                                 else room_id
                                               in
                                               ignore
                                                 (Room.broadcast_in_room ctx.config
                                                    ~room_id:target_room
                                                    ~from_agent:meta.agent_name
                                                    ~content)
                                           | Keeper_deliberation.Broadcast { message } ->
                                               ignore
                                                 (Room.broadcast ctx.config
                                                    ~from_agent:meta.agent_name
                                                    ~content:message)
                                           | Keeper_deliberation.TaskClaim { task_id; reason = _ } ->
                                               ignore
                                                 (Room.claim_task ctx.config
                                                    ~agent_name:meta.agent_name
                                                    ~task_id)
                                           | Keeper_deliberation.BoardPost { content; hearth } ->
                                               ignore
                                                 (Board_dispatch.create_post
                                                    ~author:meta.agent_name
                                                    ~content
                                                    ?hearth
                                                    ())
                                           | Keeper_deliberation.BoardComment { post_id; content } ->
                                               ignore
                                                 (Board_dispatch.add_comment
                                                    ~post_id
                                                    ~author:meta.agent_name
                                                    ~content
                                                    ())
                                           | Keeper_deliberation.BoardVote { post_id; direction } ->
                                               let dir : Board.vote_direction =
                                                 if String.lowercase_ascii direction = "down"
                                                 then Board.Down
                                                 else Board.Up
                                               in
                                               ignore
                                                 (Board_dispatch.vote
                                                    ~voter:meta.agent_name
                                                    ~post_id
                                                    ~direction:dir)
                                           | Keeper_deliberation.ProposeSpawn { topic; reason } ->
                                               let msg =
                                                 Printf.sprintf
                                                   "[spawn-proposal] %s proposes spawning agent for topic '%s': %s"
                                                   meta.name topic reason
                                               in
                                               ignore
                                                 (Room.broadcast ctx.config
                                                    ~from_agent:meta.agent_name
                                                    ~content:msg)
                                           | Keeper_deliberation.MultiStep _ ->
                                               Log.Keeper.warn "deliberation %s nested multi_step skipped"
                                                 meta.name
                                         with exn ->
                                           log_keeper_exn ~label:(Printf.sprintf "deliberation %s multi_step %d failed" meta.name !step_count) exn;
                                           stop := true)))
                                    steps_to_run);
                             (* Update meta *)
                             let updated =
                               { meta with
                                 deliberation_count =
                                   meta.deliberation_count + 1;
                                 deliberation_cost_total_usd =
                                   meta.deliberation_cost_total_usd
                                   +. turn_cost;
                                 last_deliberation_ts = now_ts;
                                 total_turns = meta.total_turns + 1;
                                 total_input_tokens =
                                   meta.total_input_tokens
                                   + response.usage.input_tokens;
                                 total_output_tokens =
                                   meta.total_output_tokens
                                   + response.usage.output_tokens;
                                 total_tokens =
                                   meta.total_tokens
                                   + response.usage.total_tokens;
                                 total_cost_usd =
                                   meta.total_cost_usd +. turn_cost;
                                 last_turn_ts = now_ts;
                                 last_model_used = response.model_used;
                                 last_input_tokens =
                                   response.usage.input_tokens;
                                 last_output_tokens =
                                   response.usage.output_tokens;
                                 last_total_tokens =
                                   response.usage.total_tokens;
                                 last_latency_ms = response.latency_ms;
                                 last_proactive_ts = now_ts;
                                 last_proactive_reason =
                                   Printf.sprintf
                                     "deliberation:%s;confidence=%.2f"
                                     (Keeper_deliberation.deliberation_action_to_legacy_string action)
                                     confidence;
                                 last_proactive_preview =
                                   short_preview reasoning;
                                 updated_at = now_iso ();
                               }
                             in
                             (match write_meta ctx.config updated with
                              | Ok () -> ()
                              | Error msg ->
                                  Log.Keeper.error "deliberation write_meta failed: %s"
                                    msg);
                             updated)))
      else
      match model_specs_of_strings meta.models with
      | Error msg ->
          log_proactive_failure ("model specs: " ^ msg);
          meta
      | Ok specs ->
          (match ensure_api_keys specs with
           | Error msg ->
               log_proactive_failure ("api keys: " ^ msg);
               meta
           | Ok () ->
               (* Phase 2: Autonomous goal turn (L2+ with active goals) *)
               (match run_autonomous_goal_turn ~config:ctx.config ~meta ~specs with
                | Some updated_meta ->
                    (match write_meta ctx.config updated_meta with
                     | Ok () -> ()
                     | Error msg ->
                         Log.Keeper.error "write_meta failed after goal turn: %s" msg);
                    updated_meta
                | None ->
               let primary =
                 match specs with
                 | p :: _ -> p
                 | [] -> Llm_client.default_local_model_spec ()
               in
               let base_dir = session_base_dir ctx.config in
               let (session, ctx_opt) =
                 load_context_from_checkpoint
                   ~trace_id:meta.trace_id
                   ~primary_model_max_tokens:primary.max_context
                   ~base_dir
               in
               match ctx_opt with
               | None ->
                   log_proactive_failure "continuity context unavailable";
                   meta
               | Some ctx_work ->
                   let continuity_snapshot = latest_state_snapshot_from_messages ctx_work.messages in
                   let continuity_summary =
                     match continuity_snapshot with
                     | Some s -> keeper_state_snapshot_to_summary_text s
                     | None -> (
                         let trimmed = String.trim meta.continuity_summary in
                         if trimmed = "" then "No continuity snapshot available." else trimmed)
                   in
                   let continuity_summary = String.trim continuity_summary in
                   let last_continuity_update_ts =
                     if
                       continuity_summary <> ""
                       && String.trim meta.continuity_summary <> continuity_summary
                     then
                       now_ts
                     else
                       meta.last_continuity_update_ts
                   in
                   let meta_for_compaction =
                     { meta with
                       continuity_summary;
                       last_continuity_update_ts
                     }
                   in
                   match
                     run_proactive_generation
                       ~specs
                       ~primary
                       ~config:ctx.config
                       ~ctx_work
                       ~meta
                       ~continuity_snapshot
                       ~continuity_summary
                       ~idle_seconds
                   with
                       | None ->
                           log_proactive_failure
                             "generation returned no proactive reply";
                           meta
                       | Some generated ->
	                       let model_used =
	                         let m = String.trim generated.model_used in
	                         if m <> "" then m else primary.model_id
	                       in
	                       let proactive_skill_route =
	                         route_keeper_skill
	                           ~soul_profile:meta.soul_profile
	                           ~message:"proactive idle checkin"
	                       in
	                       let raw_reply = generated.reply in
	                       let safe_reply =
	                         user_visible_reply_text
	                           ~fallback:(proactive_fallback_reply ~meta ~idle_seconds)
	                           raw_reply
	                       in
	                       let assistant_msg = Llm_client.assistant_msg safe_reply in
	                       let ctx_work = Context_manager.append ctx_work assistant_msg in
                       Context_manager.persist_message session assistant_msg;
                       let before_compact_tokens = ctx_work.token_count in
                       let (ctx_work, compaction_trigger, compaction_decision) =
                        compact_if_needed ~meta:meta_for_compaction ~now_ts ctx_work
                       in
                       let after_compact_tokens = ctx_work.token_count in
                       let compacted = after_compact_tokens < before_compact_tokens in
                       (try ignore (save_checkpoint session ctx_work ~generation:meta.generation)
                        with exn -> log_keeper_exn ~label:"save_checkpoint (tool_loop) failed" exn);
                       let turn_cost = generated.total_cost_usd in
                       let proactive_reason =
                         Printf.sprintf
                           "idle=%ds>=gate=%ds; cooldown_elapsed=%ds>=gate=%ds; soul=%s; skill=%s; attempts=%d; mode=tool_loop; tool_calls=%d; fallback=%d"
                           idle_seconds idle_gate cooldown_elapsed cooldown_gate meta.soul_profile
                           proactive_skill_route.primary_skill
                           generated.attempts
                           (List.length generated.tools_used)
                           (if generated.fallback_applied then 1 else 0)
                       in
                           let updated =
                             {
                               meta with
                           updated_at = now_iso ();
                           total_turns = meta.total_turns + 1;
                           total_input_tokens =
                             meta.total_input_tokens + generated.usage.input_tokens;
                           total_output_tokens =
                             meta.total_output_tokens + generated.usage.output_tokens;
                           total_tokens = meta.total_tokens + generated.usage.total_tokens;
                           total_cost_usd = meta.total_cost_usd +. turn_cost;
                           last_turn_ts = now_ts;
                           last_model_used = model_used;
                           last_input_tokens = generated.usage.input_tokens;
                           last_output_tokens = generated.usage.output_tokens;
                           last_total_tokens = generated.usage.total_tokens;
                           last_latency_ms = generated.latency_ms;
                           compaction_count =
                             meta.compaction_count + if compacted then 1 else 0;
                           last_compaction_check_ts = now_ts;
                           last_compaction_decision = compaction_decision;
                           last_compaction_ts =
                             if compacted then now_ts else meta.last_compaction_ts;
                           last_compaction_before_tokens =
                             if compacted
                             then before_compact_tokens
                             else meta.last_compaction_before_tokens;
                           last_compaction_after_tokens =
                             if compacted
                             then after_compact_tokens
                             else meta.last_compaction_after_tokens;
                           proactive_count_total = meta.proactive_count_total + 1;
                           last_proactive_ts = now_ts;
                           last_proactive_reason = proactive_reason;
                               last_proactive_preview = short_preview safe_reply;
                               continuity_summary;
                               last_continuity_update_ts;
                             }
                       in
                       (match write_meta ctx.config updated with
                        | Ok () -> ()
                        | Error msg ->
                            Log.Keeper.error "write_meta failed after proactive turn: %s" msg);
                       (try
                          let metrics_path = keeper_metrics_path ctx.config updated.name in
                          let metrics_json =
                            `Assoc
                              [
                                ("ts", `String (now_iso ()));
                                ("ts_unix", `Float now_ts);
                                ("channel", `String "proactive");
                                ("name", `String updated.name);
                                ("agent_name", `String updated.agent_name);
                                ("trace_id", `String updated.trace_id);
                                ("generation", `Int updated.generation);
                                ("model_used", `String model_used);
                                ( "usage",
                                  `Assoc
                                    [
                                      ("input_tokens", `Int generated.usage.input_tokens);
                                      ("output_tokens", `Int generated.usage.output_tokens);
                                      ("total_tokens", `Int generated.usage.total_tokens);
                                    ] );
                                ("latency_ms", `Int generated.latency_ms);
                                ("cost_usd", `Float turn_cost);
                                ("context_ratio", `Float (Context_manager.context_ratio ctx_work));
                                ("context_tokens", `Int ctx_work.token_count);
                                ("context_max", `Int ctx_work.max_tokens);
                                ("message_count", `Int (List.length ctx_work.messages));
                                ("compacted", `Bool compacted);
                                ("compaction_before_tokens", `Int before_compact_tokens);
                                ("compaction_after_tokens", `Int after_compact_tokens);
                                  ( "compaction_trigger",
                                    match compaction_trigger with
                                    | Some reason -> `String reason
                                    | None -> `Null );
                                ("compaction_decision", `String compaction_decision);
                                ("work_kind", `String "proactive_checkin");
	                                ("tool_call_count", `Int (List.length generated.tools_used));
	                                ("tools_used", `List (List.map (fun s -> `String s) generated.tools_used));
	                                ("skill_primary", `String proactive_skill_route.primary_skill);
	                                ("skill_secondary",
	                                  `List
	                                    (List.map
	                                       (fun s -> `String s)
	                                       proactive_skill_route.secondary_skills));
	                                ("skill_reason", `String proactive_skill_route.reason);
                                ("skill_selection_mode", `String "heuristic");
                                ("skill_provenance", `String "fallback");
	                                ("memory_check", memory_check_default_json ());
	                                ("proactive", `Assoc [
                                  ("performed", `Bool true);
                                  ("attempts", `Int generated.attempts);
                                  ("fallback_applied", `Bool generated.fallback_applied);
                                  ("idle_seconds", `Int idle_seconds);
                                  ("idle_gate_seconds", `Int idle_gate);
                                  ("cooldown_elapsed_seconds", `Int cooldown_elapsed);
                                  ("cooldown_gate_seconds", `Int cooldown_gate);
                                  ("reason", `String proactive_reason);
                                  ("preview", `String (short_preview safe_reply));
                                ]);
                                ("handoff", `Assoc [ ("performed", `Bool false) ]);
                              ]
                          in
                          append_jsonl_line metrics_path metrics_json
                       with exn ->
                         log_keeper_exn ~label:"metrics JSONL write failed" exn);
                       updated))

let explicit_room_prompt ~(meta : keeper_meta) ~(room_id : string) (msg : Types.message) : string =
  Printf.sprintf
    "You were explicitly mentioned in room '%s' by %s.\n\
     Mention targets: %s\n\
     Reply in-character as %s with exactly one room-ready message.\n\
     Do not include SKILL headers, STATE blocks, markdown headings, or code fences unless the user explicitly asked for them.\n\n\
     Original room message:\n%s"
    room_id
    msg.from_agent
    (String.concat ", " meta.mention_targets)
    meta.name
    msg.content

let generate_explicit_room_reply (ctx : _ context) ~(meta : keeper_meta) ~(room_id : string)
    (msg : Types.message) : (keeper_meta * string, string) result =
  let model_labels = effective_model_labels_for_turn meta ~inline_models:[] in
  match model_specs_of_strings model_labels with
  | Error e -> Error e
  | Ok specs -> (
      match ensure_api_keys specs with
      | Error e -> Error e
      | Ok () ->
          let primary =
            match specs with
            | model :: _ -> model
            | [] -> Llm_client.default_local_model_spec ()
          in
          let base_dir = session_base_dir ctx.config in
          mkdir_p base_dir;
          let (session, ctx_opt) =
            load_context_from_checkpoint
              ~trace_id:meta.trace_id
              ~primary_model_max_tokens:primary.max_context
              ~base_dir
          in
          let base_ctx =
            match ctx_opt with
            | Some current -> current
            | None ->
                Context_manager.create
                  ~system_prompt:
                    (build_keeper_system_prompt
                       ~goal:meta.goal
                       ~short_goal:meta.short_goal
                       ~mid_goal:meta.mid_goal
                       ~long_goal:meta.long_goal
                       ~soul_profile:meta.soul_profile
                       ~will:meta.will
                       ~needs:meta.needs
                       ~desires:meta.desires
                       ~instructions:meta.instructions)
                  ~max_tokens:primary.max_context
          in
          let ctx_work =
            Context_manager.set_system_prompt base_ctx
              ~system_prompt:
                (build_keeper_system_prompt
                   ~goal:meta.goal
                   ~short_goal:meta.short_goal
                   ~mid_goal:meta.mid_goal
                   ~long_goal:meta.long_goal
                   ~soul_profile:meta.soul_profile
                   ~will:meta.will
                   ~needs:meta.needs
                   ~desires:meta.desires
                   ~instructions:meta.instructions)
          in
          let prompt = explicit_room_prompt ~meta ~room_id msg in
          let user_message = Llm_client.user_msg prompt in
          let ctx_work = Context_manager.append ctx_work user_message in
          Context_manager.persist_message session user_message;
          let requests =
            List.map
              (fun (model : Llm_client.model_spec) ->
                ({
                  Llm_client.model;
                  messages = (Llm_client.system_msg ctx_work.system_prompt) :: ctx_work.messages;
                  temperature = Keeper_config.keeper_reflection_temp ();
                  max_tokens = 256;
                  tools = [];
                  response_format = `Text;
                } : Llm_client.completion_request))
              specs
          in
          match Llm_client.cascade requests with
          | Error e -> Error e
          | Ok resp ->
              let used_model =
                model_spec_for_used specs resp.model_used |> Option.value ~default:primary
              in
              let reply_raw = String.trim resp.content in
              let reply =
                if reply_raw = "" then
                  Printf.sprintf "@%s 야, 다시 한 번만 말해봐." msg.from_agent
                else
                  reply_raw
              in
              let assistant_message = Llm_client.assistant_msg reply in
              let ctx_work = Context_manager.append ctx_work assistant_message in
              Context_manager.persist_message session assistant_message;
              (try ignore (save_checkpoint session ctx_work ~generation:meta.generation)
               with exn ->
                 log_keeper_exn ~label:"save_checkpoint (explicit room reply) failed" exn);
              let usage = resp.usage in
              let now_ts = Time_compat.now () in
              let updated =
                {
                  meta with
                  updated_at = now_iso ();
                  total_turns = meta.total_turns + 1;
                  total_input_tokens = meta.total_input_tokens + usage.input_tokens;
                  total_output_tokens = meta.total_output_tokens + usage.output_tokens;
                  total_tokens = meta.total_tokens + usage.total_tokens;
                  total_cost_usd =
                    meta.total_cost_usd +. cost_usd_of_usage usage used_model;
                  last_turn_ts = now_ts;
                  last_model_used = resp.model_used;
                  last_input_tokens = usage.input_tokens;
                  last_output_tokens = usage.output_tokens;
                  last_total_tokens = usage.total_tokens;
                  last_latency_ms = resp.latency_ms;
                }
              in
              Ok (updated, reply))

let social_board_event_prompt ~(meta : keeper_meta) (event : social_board_event) : string =
  let event_kind =
    match event.kind with
    | `Board_post -> "board_post"
    | `Board_comment -> "board_comment"
  in
  let comment_hint =
    match event.comment_id with
    | Some id -> Printf.sprintf "\nComment ID: %s" id
    | None -> ""
  in
  Printf.sprintf
    "You are resident keeper %s acting in the room's public square.\n\
     A new board event requires triage.\n\n\
     Event type: %s\n\
     Post ID: %s%s\n\
     Author: %s\n\
     Content preview:\n%s\n\n\
     If you act, use tools directly.\n\
     Preferred action order:\n\
     1. `keeper_board_comment` when a direct reply is sufficient.\n\
     2. `keeper_board_vote` when a lightweight signal is enough.\n\
     3. `keeper_board_post` only for broader escalation or synthesis.\n\
     If no action is warranted, explain briefly why you passed.\n\
     Never respond to your own board event.\n\
     Stay in character and keep any final text concise."
    meta.name
    event_kind
    event.post_id
    comment_hint
    event.author
    event.content

let run_social_board_event_turn
    (ctx : _ context)
    ~(meta : keeper_meta)
    ~(event : social_board_event) : (keeper_meta * social_turn_outcome, string) result =
  let model_labels = effective_model_labels_for_turn meta ~inline_models:[] in
  match model_specs_of_strings model_labels with
  | Error e -> Error e
  | Ok specs -> (
      match ensure_api_keys specs with
      | Error e -> Error e
      | Ok () ->
          let primary =
            match specs with
            | model :: _ -> model
            | [] -> Llm_client.default_local_model_spec ()
          in
          let base_dir = session_base_dir ctx.config in
          let session, ctx_opt =
            load_context_from_checkpoint
              ~trace_id:meta.trace_id
              ~primary_model_max_tokens:primary.max_context
              ~base_dir
          in
          let base_ctx =
            match ctx_opt with
            | Some current -> current
            | None ->
                Context_manager.create
                  ~system_prompt:
                    (build_keeper_system_prompt
                       ~goal:meta.goal
                       ~short_goal:meta.short_goal
                       ~mid_goal:meta.mid_goal
                       ~long_goal:meta.long_goal
                       ~soul_profile:meta.soul_profile
                       ~will:meta.will
                       ~needs:meta.needs
                       ~desires:meta.desires
                       ~instructions:meta.instructions)
                  ~max_tokens:primary.max_context
          in
          let ctx_work =
            Context_manager.set_system_prompt base_ctx
              ~system_prompt:
                (build_keeper_system_prompt
                   ~goal:meta.goal
                   ~short_goal:meta.short_goal
                   ~mid_goal:meta.mid_goal
                   ~long_goal:meta.long_goal
                   ~soul_profile:meta.soul_profile
                   ~will:meta.will
                   ~needs:meta.needs
                   ~desires:meta.desires
                   ~instructions:meta.instructions)
          in
          let prompt = social_board_event_prompt ~meta event in
          let user_message = Llm_client.user_msg prompt in
          let ctx_work = Context_manager.append ctx_work user_message in
          Context_manager.persist_message session user_message;
          let execute_tool_calls
              ~(ctx_work : Context_manager.working_context)
              (tcs : Llm_client.tool_call list) : (Llm_client.tool_call * string) list =
            List.map
              (fun (tc : Llm_client.tool_call) ->
                 let output =
                   try execute_keeper_tool_call ~config:ctx.config ~meta ~ctx_work tc
                   with exn ->
                     Yojson.Safe.to_string
                       (`Assoc
                         [
                           ("error", `String (Printexc.to_string exn));
                           ("tool", `String tc.call_name);
                         ])
                 in
                 (tc, output))
              tcs
          in
          let requests =
            List.map
              (fun (model : Llm_client.model_spec) ->
                 ({
                    Llm_client.model;
                    messages =
                      (Llm_client.system_msg ctx_work.system_prompt)
                      :: (ctx_work.messages @ [ Llm_client.user_msg prompt ]);
                    temperature = Keeper_config.keeper_planning_temp ();
                    max_tokens = 768;
                    tools = keeper_allowed_llm_tools meta;
                    response_format = `Text;
                  }
                   : Llm_client.completion_request))
              specs
          in
          match Llm_client.cascade requests with
          | Error e -> Error e
          | Ok resp0 ->
              let max_tool_rounds = 3 in
              let used_model0 =
                model_spec_for_used specs resp0.model_used
                |> Option.value ~default:primary
              in
              let cost0 = cost_usd_of_usage resp0.usage used_model0 in
              let rec tool_loop ~round ~acc_usage ~acc_latency ~acc_cost
                  ~acc_tools_used ~last_resp =
                if last_resp.Llm_client.tool_calls = [] || round > max_tool_rounds then
                  let content =
                    let trimmed = String.trim last_resp.Llm_client.content in
                    if trimmed = "" && acc_tools_used <> [] then
                      Printf.sprintf "(tools executed: %s)"
                        (String.concat ", " acc_tools_used)
                    else
                      last_resp.Llm_client.content
                  in
                  ( content,
                    acc_usage,
                    last_resp.Llm_client.model_used,
                    acc_latency,
                    acc_cost,
                    acc_tools_used )
                else
                  let round_tools =
                    List.map
                      (fun (tc : Llm_client.tool_call) -> tc.call_name)
                      last_resp.Llm_client.tool_calls
                  in
                  let all_tools_so_far = acc_tools_used @ round_tools in
                  let tool_outputs =
                    execute_tool_calls ~ctx_work last_resp.Llm_client.tool_calls
                  in
                  let followup_prompt =
                    keeper_tool_followup_prompt
                      ~user_message:prompt
                      ~draft_reply:last_resp.Llm_client.content
                      ~tool_outputs
                      ~already_executed:all_tools_so_far
                  in
                  let next_tools =
                    keeper_allowed_llm_tools
                      ~write_done:(keeper_write_done all_tools_so_far)
                      meta
                  in
                  let followup_requests =
                    List.map
                      (fun (model : Llm_client.model_spec) ->
                         ({
                            Llm_client.model;
                            messages = [
                              Llm_client.system_msg
                                (keeper_tool_loop_system_prompt
                                   ~character_context:ctx_work.system_prompt);
                              Llm_client.user_msg followup_prompt;
                            ];
                            temperature = Keeper_config.keeper_deterministic_temp ();
                            max_tokens = 512;
                            tools = next_tools;
                            response_format = `Text;
                          }
                           : Llm_client.completion_request))
                      specs
                  in
                  match Llm_client.cascade followup_requests with
                  | Error _ ->
                      ( last_resp.Llm_client.content,
                        acc_usage,
                        last_resp.Llm_client.model_used,
                        acc_latency,
                        acc_cost,
                        acc_tools_used @ round_tools )
                  | Ok resp_next ->
                      let used_model_next =
                        model_spec_for_used specs resp_next.model_used
                        |> Option.value ~default:primary
                      in
                      let cost_next = cost_usd_of_usage resp_next.usage used_model_next in
                      tool_loop
                        ~round:(round + 1)
                        ~acc_usage:(merge_usage acc_usage resp_next.usage)
                        ~acc_latency:(acc_latency + resp_next.latency_ms)
                        ~acc_cost:(acc_cost +. cost_next)
                        ~acc_tools_used:(acc_tools_used @ round_tools)
                        ~last_resp:resp_next
              in
              let final_content, final_usage, final_model_used, final_latency_ms,
                  final_cost_usd, final_tools_used =
                tool_loop
                  ~round:1
                  ~acc_usage:resp0.usage
                  ~acc_latency:resp0.latency_ms
                  ~acc_cost:cost0
                  ~acc_tools_used:[]
                  ~last_resp:resp0
              in
              let assistant_text =
                let trimmed = String.trim final_content in
                if trimmed = "" && final_tools_used = [] then
                  "Inspected the board event and chose not to act."
                else if trimmed = "" then
                  Printf.sprintf "(tools executed: %s)" (String.concat ", " final_tools_used)
                else
                  trimmed
              in
              let assistant_message = Llm_client.assistant_msg assistant_text in
              let ctx_work = Context_manager.append ctx_work assistant_message in
              Context_manager.persist_message session assistant_message;
              (try ignore (save_checkpoint session ctx_work ~generation:meta.generation)
               with exn ->
                 log_keeper_exn ~label:"save_checkpoint (social board turn) failed" exn);
              let now_ts = Time_compat.now () in
              let action_kind = keeper_action_kind_of_tool_names final_tools_used in
              let outcome =
                if action_kind = "none" then `Passed else `Acted
              in
              let updated_meta =
                {
                  meta with
                  updated_at = now_iso ();
                  total_turns = meta.total_turns + 1;
                  total_input_tokens = meta.total_input_tokens + final_usage.input_tokens;
                  total_output_tokens = meta.total_output_tokens + final_usage.output_tokens;
                  total_tokens = meta.total_tokens + final_usage.total_tokens;
                  total_cost_usd = meta.total_cost_usd +. final_cost_usd;
                  last_turn_ts = now_ts;
                  last_model_used = final_model_used;
                  last_input_tokens = final_usage.input_tokens;
                  last_output_tokens = final_usage.output_tokens;
                  last_total_tokens = final_usage.total_tokens;
                  last_latency_ms = final_latency_ms;
                  last_autonomous_action_at =
                    (if action_kind = "none" then meta.last_autonomous_action_at else now_iso ());
                  autonomous_action_count =
                    meta.autonomous_action_count + if action_kind = "none" then 0 else 1;
                }
              in
              Ok
                ( updated_meta,
                  {
                    outcome;
                    summary = assistant_text;
                    reason = assistant_text;
                    action_kind;
                    tools_used = final_tools_used;
                    decision_reason = Some assistant_text;
                    failure_reason = None;
                  } ))

let run_learned_policy_room_event
    (ctx : _ context)
    ~(meta : keeper_meta)
    ~(room_id : string)
    (msg : Types.message) : (keeper_meta, string) result =
  let reward_model_path = String.trim meta.policy_reward_model_path in
  match load_keeper_reward_model reward_model_path with
  | Error e -> Error e
  | Ok reward_model ->
      let action_budget = Keeper_contract.policy_action_budget_of_string meta.policy_action_budget in
      let observation = keeper_policy_observation_of_room_message ~meta ~room_id msg in
      let feature_vector = keeper_policy_feature_vector observation in
      let candidate_actions =
        [ ("noop", true); ("reply_in_room", true) ]
        @
        if action_budget = Keeper_contract.Board then [ ("board_post", true) ] else []
      in
      let candidate_scores =
        List.map
          (fun (action, allowed) ->
            score_keeper_policy_candidate
              ~model:reward_model
              ~features:feature_vector
              ~action
              ~allowed)
          candidate_actions
      in
      let chosen_candidate =
        choose_policy_action candidate_scores
        |> Option.value
             ~default:
               {
                 action = "noop";
                 bias = 0.0;
                 feature_scores = [];
                 score = 0.0;
                 allowed = true;
               }
      in
      let action_id = generate_trace_id () in
      let now_ts = Time_compat.now () in
      let execution_result, updated_meta =
        match chosen_candidate.action with
        | "reply_in_room" -> (
            match generate_explicit_room_reply ctx ~meta ~room_id msg with
            | Error e ->
                ( `Assoc
                    [
                      ("executed", `Bool false);
                      ("error", `String e);
                    ],
                  meta )
            | Ok (updated_meta, reply) ->
                (try
                   ignore
                     (Room.broadcast_in_room ctx.config ~room_id
                        ~from_agent:updated_meta.agent_name ~content:reply)
                 with exn ->
                   log_keeper_exn ~label:(Printf.sprintf "learned policy room broadcast failed for %s in %s" updated_meta.name room_id) exn);
                ( `Assoc
                    [
                      ("executed", `Bool true);
                      ("reply", `String reply);
                      ("reply_preview", `String (short_preview reply));
                    ],
                  updated_meta ))
        | "board_post" ->
            let title =
              Printf.sprintf "[keeper:%s] %s mentioned in %s"
                meta.name msg.from_agent room_id
            in
            let content =
              Printf.sprintf
                "Learned-policy board escalation.\n\n- Keeper: %s\n- Room: %s\n- Mentioned by: %s\n- Message: %s"
                meta.name
                room_id
                msg.from_agent
                (short_preview ~max_len:400 msg.content)
            in
            let board_args =
              `Assoc
                [
                  ("author", `String meta.name);
                  ("title", `String title);
                  ("content", `String content);
                  ("tags",
                    `List
                      [
                        `String "keeper-policy";
                        `String "learned-offline-v1";
                        `String meta.name;
                      ]);
                ]
            in
            let board_args =
              ensure_keeper_board_post_args ~author:meta.name
                ~source:"keeper_policy_learned_offline" board_args
            in
            let ok, result = Tool_board.handle_tool "masc_board_post" board_args in
            if ok then
              let updated_meta =
                {
                  meta with
                  updated_at = now_iso ();
                  last_autonomous_action_at = now_iso ();
                  autonomous_action_count = meta.autonomous_action_count + 1;
                }
              in
              ( `Assoc
                  [
                    ("executed", `Bool true);
                    ("title", `String title);
                    ("board_result",
                      try Yojson.Safe.from_string result with Yojson.Json_error _ -> `String result);
                  ],
                updated_meta )
            else
              ( `Assoc
                  [
                    ("executed", `Bool false);
                    ("error", `String result);
                  ],
                meta )
        | _ ->
            (`Assoc [("executed", `Bool false); ("result", `String "noop")], meta)
      in
      let log_json =
        `Assoc
          [
            ("ts", `String (now_iso ()));
            ("ts_unix", `Float now_ts);
            ("action_id", `String action_id);
            ("keeper", `String meta.name);
            ("trace_id", `String meta.trace_id);
            ("policy_mode", `String meta.policy_mode);
            ( "policy_action_budget",
              `String (Keeper_contract.policy_action_budget_to_string action_budget) );
            ("reward_model", `String reward_model.version);
            ("reward_model_path", `String reward_model.path);
            ("observation", keeper_policy_observation_to_json observation);
            ("feature_vector", float_assoc_to_json feature_vector);
            ("candidates", `List (List.map keeper_policy_candidate_score_to_json candidate_scores));
            ("chosen_action", `String chosen_candidate.action);
            ("chosen_score", `Float chosen_candidate.score);
            ("heuristic_baseline_action",
              `String (deterministic_policy_baseline_action observation));
            ("safety_gate",
              `Assoc
                [
                  ("allowed", `Bool chosen_candidate.allowed);
                  ("reason", `String "conversation_and_board_only");
                ]);
            ("result", execution_result);
          ]
      in
      append_jsonl_line (keeper_policy_log_path ctx.config meta.name) log_json;
      Ok updated_meta

let maybe_emit_explicit_room_replies (ctx : _ context) (meta : keeper_meta) : keeper_meta =
  if
    meta.trigger_mode
    |> Keeper_contract.trigger_mode_of_string
    |> Keeper_contract.trigger_mode_is_explicit_only
    |> not
  then
    meta
  else
    let meta = ensure_keeper_room_presence ctx.config meta in
    let targets =
      if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
    in
    let batch_limit = Keeper_config.keeper_batch_limit () in
    let next_meta =
      List.fold_left
        (fun meta_acc room_id ->
          let since_seq = room_cursor_for meta_acc room_id in
          let messages =
            Room.get_messages_raw_in_room ctx.config ~room_id ~since_seq ~limit:batch_limit
          in
          let max_seq =
            List.fold_left (fun best (msg : Types.message) -> max best msg.seq) since_seq messages
          in
          let meta_after_messages =
            List.fold_left
              (fun current_meta (msg : Types.message) ->
                if msg.from_agent = current_meta.agent_name then
                  current_meta
                else if not (exact_direct_mention_present ~targets msg.content) then
                  current_meta
                else
                  if keeper_policy_mode_is_learned current_meta then
                    (match run_learned_policy_room_event ctx ~meta:current_meta ~room_id msg with
                     | Error err ->
                         Log.Keeper.error "learned policy room action failed for %s in %s: %s"
                           current_meta.name room_id err;
                         current_meta
                     | Ok updated_meta ->
                         (match write_meta ctx.config updated_meta with
                          | Ok () -> ()
                          | Error err ->
                              Log.Keeper.error "write_meta after learned policy room action failed: %s"
                                err);
                         updated_meta)
                  else
                    match generate_explicit_room_reply ctx ~meta:current_meta ~room_id msg with
                    | Error err ->
                        Log.Keeper.error "explicit room reply failed for %s in %s: %s"
                          current_meta.name room_id err;
                        current_meta
                    | Ok (updated_meta, reply) ->
                        (try
                           ignore
                             (Room.broadcast_in_room ctx.config ~room_id
                                ~from_agent:updated_meta.agent_name ~content:reply)
                         with exn ->
                           log_keeper_exn ~label:(Printf.sprintf "explicit room broadcast failed for %s in %s" updated_meta.name room_id) exn);
                        (match write_meta ctx.config updated_meta with
                         | Ok () -> ()
                         | Error err ->
                             Log.Keeper.error "write_meta after explicit room reply failed: %s"
                               err);
                        updated_meta)
              meta_acc
              messages
          in
          let updated_meta = set_room_cursor meta_after_messages room_id max_seq in
          let updated_meta =
            { updated_meta with joined_room_ids = dedupe_keep_order (room_id :: updated_meta.joined_room_ids) }
          in
          (match write_meta ctx.config updated_meta with
           | Ok () -> ()
           | Error err ->
               Log.Keeper.error "write_meta after room cursor update failed: %s" err);
          updated_meta)
        meta
        meta.joined_room_ids
    in
    next_meta
