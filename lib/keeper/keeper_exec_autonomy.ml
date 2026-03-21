(** Keeper_exec_autonomy — autonomous execution engine:
    gate config, plan execution, and autonomous goal turns.

    Autonomy level dispatch removed. Uses flat default gate config.
    The autonomy_level string is kept in keeper_meta for backward compat
    but no longer drives gate config selection. *)

open Keeper_types
open Keeper_memory
open Keeper_exec_tools
open Keeper_exec_context

(* ================================================================ *)
(* Default Gate Config                                               *)
(* ================================================================ *)

(** Flat default gate config for keeper execution.
    Restricts allowed tools to safe, read-only + board operations. *)
let autonomous_gate_config () : Eval_gate.gate_config =
  {
    max_cost_usd = 0.10;
    max_tool_calls_per_turn = 5;
    entropy_threshold = 2;
    destructive_check_enabled = true;
    allowlist_enabled = true;
    allowed_tools = [
      "keeper_board_get"; "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote"; "keeper_board_list";
      "keeper_read"; "keeper_fs_read";
      "keeper_memory_search";
      "keeper_time_now"; "keeper_context_status";
    ];
    denied_tools = [
      "keeper_bash"; "keeper_edit"; "keeper_fs_edit"; "keeper_github";
    ];
  }

(* ================================================================ *)
(* Execute Approved Plan                                             *)
(* ================================================================ *)

let execute_approved_plan
    ~(config : Room.config)
    ~(meta : keeper_meta)
    ~(specs : Model_spec.model_spec list)
    ~(plan : string)
    ~(pa : Keeper_verifier.proposed_action)
    ~(trajectory_acc : Trajectory.accumulator option)
    : string * float * string list =
  ignore trajectory_acc;
  let gate_config = autonomous_gate_config () in
  let primary = match specs with p :: _ -> p | [] -> Model_spec.default_local_model_spec () in
  let autonomy_system_prompt = Printf.sprintf
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
  let max_rounds = 3 in
  let guardrails = Verifier_oas.eval_gate_to_oas_guardrails gate_config in
  let base_dir = session_base_dir config in
  let build_turn_prompt ~base_system_prompt:_ ~messages:_ =
    autonomy_system_prompt
  in
  match Keeper_agent_run.run_turn
    ~config ~meta ~base_dir
    ~max_context:primary.max_context
    ~build_turn_prompt
    ~user_message:"Execute the first step of the plan now."
    ~cascade_name:"keeper_autonomy"
    ~generation:meta.generation
    ~max_turns:max_rounds
    ~guardrails
    ~temperature:0.3
    ~max_tokens:1024
    ~max_cost_usd:gate_config.Eval_gate.max_cost_usd
    ()
  with
  | Error e ->
      (Printf.sprintf "OAS agent failed: %s" e, 0.0, [])
  | Ok result ->
      let content =
        let c = String.trim result.response_text in
        if c = "" then "(autonomous execution completed)" else c
      in
      let used_model_spec =
        model_spec_for_used specs result.model_used
        |> Option.value ~default:primary
      in
      let cost = cost_usd_of_usage result.usage used_model_spec in
      (content, cost, result.tools_used)

(* ================================================================ *)
(* Autonomous Goal Turn                                              *)
(* ================================================================ *)

(** Autonomous goal turn: evaluate goals and optionally generate/verify action plan.
    Returns Some updated_meta when an autonomous action decision was made,
    None to fall through to regular proactive generation. *)
let run_autonomous_goal_turn ~(config : Room.config) ~(meta : keeper_meta)
    ~(specs : Model_spec.model_spec list) : keeper_meta option =
  if meta.active_goal_ids = [] then None
  else
    let keeper_context =
      Printf.sprintf "keeper=%s turns=%d cost=$%.4f"
        meta.name meta.total_turns meta.total_cost_usd
    in
    (* Full pipeline: evaluate, plan, verify, decide *)
    let result = Keeper_verifier.run_pipeline
      ~config
      ~goal_ids:meta.active_goal_ids
      ~keeper_name:meta.name
      ~keeper_context
    in
    (match result with
     | NothingToDo reason ->
         Log.KeeperExec.info "%s: nothing to do (%s)" meta.name reason;
         None
     | PerpetualRequested req ->
         Log.KeeperExec.info "%s PERPETUAL: starting for %s"
           meta.name req.goal_title;
         let effective_coding_mode = false in
         (if req.coding_mode then
            Log.KeeperExec.info "%s: coding_mode requested but unavailable (no Eio.Switch in heartbeat context), falling back to MODEL-only" meta.name);
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
              (try ignore (Goal_store.review_goal config
                ~goal_id:req.goal_id ~outcome:"progress"
                ~note:(Printf.sprintf "Perpetual agent started (models: %s)"
                  (String.concat ", " req.models)) ()) with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                log_keeper_exn ~label:"goal review failed" exn);
              let board_args = `Assoc [
                ("author", `String meta.name);
                ("title", `String (Printf.sprintf "[Perpetual] %s" req.goal_title));
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
               | exception (Eio.Cancel.Cancelled _ as e) -> raise e
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
         let masc_root = Filename.concat config.base_path ".masc" in
         let traj_acc = Trajectory.create_accumulator
           ~masc_root
           ~keeper_name:meta.name
           ~trace_id:(Printf.sprintf "keeper-auto-%s-%d"
             meta.name meta.autonomous_action_count)
           ~generation:meta.generation in
         (try Sse.broadcast (`Assoc [
           ("type", `String "keeper_autonomy_start");
           ("name", `String meta.name);
           ("goal_id", `String pa.goal_id);
           ("action", `String pa.action_description);
         ]) with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           log_keeper_exn ~label:"SSE keeper_autonomy_start broadcast failed" exn);
         let (summary, exec_cost, tools_used) =
           execute_approved_plan ~config ~meta ~specs ~plan ~pa
             ~trajectory_acc:(Some traj_acc) in
         (try ignore (Trajectory.finalize traj_acc Trajectory.Completed)
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> log_keeper_exn ~label:"trajectory finalize failed" exn);
         let outcome = if tools_used <> [] then "progress" else "blocked" in
         let review_note = Printf.sprintf
           "Autonomous execution: %s | tools: [%s] | cost: $%.4f"
           (if String.length summary > 200 then String.sub summary 0 200 ^ "..." else summary)
           (String.concat ", " tools_used)
           exec_cost in
         (try ignore (Goal_store.review_goal config
           ~goal_id:pa.goal_id ~outcome ~note:review_note ()) with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
           log_keeper_exn ~label:"goal review failed" exn);
         let report_args = `Assoc [
           ("author", `String meta.name);
           ("title", `String (Printf.sprintf "[Execution] %s" pa.goal_title));
           ("content", `String (Printf.sprintf
             "Execution result: %s\n\n- Tools used: [%s]\n- Cost: $%.4f\n- Goal: %s (id=%s)\n- Outcome: %s"
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
         (try Sse.broadcast (`Assoc [
           ("type", `String "keeper_autonomy_complete");
           ("name", `String meta.name);
           ("goal_id", `String pa.goal_id);
           ("result", `String outcome);
           ("tools_used", `List (List.map (fun t -> `String t) tools_used));
           ("cost_usd", `Float exec_cost);
         ]) with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
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
         let masc_root = Filename.concat config.base_path ".masc" in
         let traj_acc = Trajectory.create_accumulator
           ~masc_root
           ~keeper_name:meta.name
           ~trace_id:(Printf.sprintf "keeper-auto-%s-%d-cautioned"
             meta.name meta.autonomous_action_count)
           ~generation:meta.generation in
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
         (try Sse.broadcast (`Assoc [
           ("type", `String "keeper_autonomy_start");
           ("name", `String meta.name);
           ("goal_id", `String pa.goal_id);
           ("action", `String pa.action_description);
           ("caution", `String warning);
         ]) with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           log_keeper_exn ~label:"SSE keeper_autonomy_start (cautioned) broadcast failed" exn);
         let (summary, exec_cost, tools_used) =
           execute_approved_plan ~config ~meta ~specs ~plan ~pa
             ~trajectory_acc:(Some traj_acc) in
         (try ignore (Trajectory.finalize traj_acc Trajectory.Completed)
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> log_keeper_exn ~label:"trajectory finalize (cautioned) failed" exn);
         let outcome = if tools_used <> [] then "progress" else "blocked" in
         let review_note = Printf.sprintf
           "Cautioned execution (warning: %s): %s | tools: [%s] | cost: $%.4f"
           warning
           (if String.length summary > 150 then String.sub summary 0 150 ^ "..." else summary)
           (String.concat ", " tools_used)
           exec_cost in
         (try ignore (Goal_store.review_goal config
           ~goal_id:pa.goal_id ~outcome ~note:review_note ()) with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
           log_keeper_exn ~label:"goal review (cautioned) failed" exn);
         let report_args = `Assoc [
           ("author", `String meta.name);
           ("title", `String (Printf.sprintf "[Execution (cautioned)] %s" pa.goal_title));
           ("content", `String (Printf.sprintf
             "Warning: %s\n\nExecution result: %s\n\n- Tools: [%s]\n- Cost: $%.4f\n- Goal: %s (id=%s)"
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
         ]) with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
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
