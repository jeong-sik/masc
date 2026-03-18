(** Keeper_exec_autonomy — autonomous execution engine (Phase 5):
    gate config, plan execution, and autonomous goal turns. *)

open Keeper_types
open Keeper_memory
open Keeper_exec_tools
open Keeper_exec_context

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
        max_cost_usd = 0.10;
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
        max_cost_usd = 0.50;
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
        max_cost_usd = 0.10;
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
    ~(specs : Llm_types.model_spec list)
    ~(plan : string)
    ~(pa : Keeper_autonomy.proposed_action)
    ~(autonomy_level : Keeper_autonomy.autonomy_level)
    ~(trajectory_acc : Trajectory.accumulator option)
    : string * float * string list =
  let gate_config = autonomous_gate_config ~autonomy_level in
  let primary = match specs with p :: _ -> p | [] -> Llm_types.default_local_model_spec () in
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
      (tcs : Llm_types.tool_call list) : (Llm_types.tool_call * string) list =
    List.map
      (fun (tc : Llm_types.tool_call) ->
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
               Log.KeeperExec.info "GATE BLOCKED %s: %s"
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
  let run_cascade requests = Llm_orchestration.cascade requests in
  let max_rounds = 3 in
  let initial_request =
    { Llm_types.model = primary;
      messages = [
        Agent_sdk.Types.system_msg system_prompt;
        Agent_sdk.Types.user_msg "Execute the first step of the plan now.";
      ];
      temperature = 0.3;
      max_tokens = 1024;
      tools = keeper_allowed_llm_tools meta;
      response_format = `Text;
    }
  in
  let requests = List.map (fun (spec : Llm_types.model_spec) ->
    { initial_request with Llm_types.model = spec }
  ) specs in
  match run_cascade requests with
  | Error e ->
      (Printf.sprintf "LLM cascade failed: %s" e, 0.0, [])
  | Ok resp0 ->
      let rec exec_loop ~round ~acc_cost ~acc_tools ~last_resp =
        if not (Llm_types.has_tool_calls last_resp) || round > max_rounds then
          let content =
            let c = String.trim (Llm_types.text_of_response last_resp) in
            if c = "" && acc_tools <> [] then
              Printf.sprintf "(autonomous execution: %s)"
                (String.concat ", " acc_tools)
            else c
          in
          (content, acc_cost, acc_tools)
        else
          let last_resp_tool_calls = Llm_types.tool_calls_of_response last_resp in
          let round_tools =
            List.map (fun (tc : Llm_types.tool_call) -> tc.call_name)
              last_resp_tool_calls
          in
          let all_tools = acc_tools @ round_tools in
          let tool_outputs = execute_tool_calls last_resp_tool_calls in
          let followup_prompt =
            keeper_tool_followup_prompt
              ~user_message:"Execute the next step of the plan."
              ~draft_reply:(Llm_types.text_of_response last_resp)
              ~tool_outputs
              ~already_executed:all_tools
          in
          (* Stop providing tools after write operations *)
          let write_done =
            keeper_write_done all_tools
          in
          let next_tools = keeper_allowed_llm_tools ~write_done meta in
          let followup_requests = List.map (fun (spec : Llm_types.model_spec) ->
            { Llm_types.model = spec;
              messages = [
                Agent_sdk.Types.system_msg system_prompt;
                Agent_sdk.Types.user_msg followup_prompt;
              ];
              temperature = 0.3;
              max_tokens = 1024;
              tools = next_tools;
              response_format = `Text;
            }
          ) specs in
          match run_cascade followup_requests with
          | Error _ ->
              (Llm_types.text_of_response last_resp, acc_cost, all_tools)
          | Ok next_resp ->
              let used_spec =
                model_spec_for_used specs next_resp.Llm_provider.Types.model
                |> Option.value ~default:primary
              in
              let round_cost = cost_usd_of_usage (Llm_types.usage_of_response next_resp) used_spec in
              exec_loop ~round:(round + 1)
                ~acc_cost:(acc_cost +. round_cost)
                ~acc_tools:all_tools
                ~last_resp:next_resp
      in
      let used_spec0 =
        model_spec_for_used specs resp0.Llm_provider.Types.model
        |> Option.value ~default:primary
      in
      let cost0 = cost_usd_of_usage (Llm_types.usage_of_response resp0) used_spec0 in
      exec_loop ~round:1 ~acc_cost:cost0 ~acc_tools:[] ~last_resp:resp0

(** Autonomous goal turn: evaluate goals and optionally generate/verify action plan.
    Returns Some updated_meta when an autonomous action decision was made,
    None to fall through to regular proactive generation.
    @since 2.74.0 *)
let run_autonomous_goal_turn ~(config : Room.config) ~(meta : keeper_meta)
    ~(specs : Llm_types.model_spec list) : keeper_meta option =
  if not (keeper_autonomy_enabled ()) then None
  else if meta.active_goal_ids = [] then None
  else
    match Keeper_contract.parse_autonomy_level meta.autonomy_level with
    | None -> None
    | Some L1_Reactive -> None
    | Some level ->
        let primary = match specs with p :: _ -> p | [] -> Llm_types.default_local_model_spec () in
        let verify_model =
          match Llm_types.default_verifier_model_spec () with
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
                 Log.KeeperExec.info "%s L2 suggest: %s (risk=%s, cost=$%.2f)"
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
                   Log.KeeperExec.error "%s L2 board post failed" meta.name;
                 Some { meta with
                   last_autonomous_action_at = now_iso ();
                   autonomous_action_count = meta.autonomous_action_count + 1;
                   updated_at = now_iso ();
                 }
             | StartPerpetualAgent req ->
                 Log.KeeperExec.info "%s L2 perpetual suggest: %s"
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
                      Log.KeeperExec.error "%s L2 perpetual board post failed: %s" meta.name err
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
                 Log.KeeperExec.info "%s: nothing to do (%s)" meta.name reason;
                 None
             | PerpetualRequested req ->
                 Log.KeeperExec.info "%s PERPETUAL: starting for %s"
                   meta.name req.goal_title;
                 (* Keeper runs in heartbeat timer context without Eio.Switch.t,
                    so coding_mode (= Claude Code spawn) is structurally unavailable.
                    Force LLM-only mode to prevent guaranteed failure. *)
                 let effective_coding_mode = false in
                 (if req.coding_mode then
                    Log.KeeperExec.info "%s: coding_mode requested but unavailable (no Eio.Switch in heartbeat context), falling back to LLM-only" meta.name);
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
                      Log.KeeperExec.info "%s perpetual started: %s"
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
                           Log.KeeperExec.error "%s: board post failed: %s" meta.name err
                       | exception exn ->
                           log_keeper_exn ~label:(Printf.sprintf "autonomy %s board post error" meta.name) exn);
                      Some { meta with
                        last_autonomous_action_at = now_iso ();
                        autonomous_action_count = meta.autonomous_action_count + 1;
                        updated_at = now_iso ();
                      }
                  | Some (false, err) ->
                      Log.KeeperExec.error "%s perpetual start failed: %s"
                        meta.name err;
                      None
                  | None ->
                      Log.KeeperExec.info "%s perpetual dispatch returned None" meta.name;
                      None)
             | Approved (pa, plan) ->
                 Log.KeeperExec.info "%s APPROVED: %s"
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
                 Log.KeeperExec.warn "%s CAUTIONED: %s (warning: %s)"
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
                 Log.KeeperExec.info "%s REJECTED: %s (%s)"
                   meta.name pa.action_description reason;
                 None)
