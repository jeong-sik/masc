(** Keeper_turn -- keeper lifecycle and message-turn handlers.

    Orchestrates keeper turns by building domain-specific system prompt
    configuration and delegating to {!Keeper_agent_run.run_turn} which
    owns the full OAS-backed context lifecycle (checkpoint, prompt state,
    Agent.run).

    Sub-modules:
    - Keeper_turn_up: start/reconfigure
    - Keeper_turn_session: team-session helpers
    - Keeper_turn_setup: ensure_keeper_exists
    - Keeper_turn_lifecycle: shutdown *)

open Tool_args
open Keeper_types
open Keeper_memory [@@warning "-33"]
open Keeper_alerting [@@warning "-33"]
open Keeper_exec_tools [@@warning "-33"]
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_setup

type tool_result = Keeper_types.tool_result

let handle_keeper_up = Keeper_turn_up.handle_keeper_up
let handle_keeper_down = Keeper_turn_lifecycle.handle_keeper_down

(* -- handle_keeper_msg: orchestrator ---------------------------------------- *)

let handle_keeper_msg ?on_text_delta ctx args : tool_result =
  let on_event = match on_text_delta with
    | None -> None
    | Some cb -> Some (fun (evt : Agent_sdk.Types.sse_event) ->
        match evt with
        | Agent_sdk.Types.ContentBlockDelta { delta = TextDelta text; _ } -> cb text
        | _ -> ())
  in
  let name = get_string args "name" "" in
  let message = get_string args "message" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if message = "" then
    (false, "❌ message is required")
  else
    let turn_instructions = get_string_opt args "turn_instructions" in
    let no_skill_route = get_bool args "no_skill_route" false in
    let no_state_block = get_bool args "no_state_block" false in
    let direct_reply = get_bool args "direct_reply" false in
    (match reject_legacy_model_args ~tool_name:"masc_keeper_msg" args with
    | Error e -> (false, "❌ " ^ e)
    | Ok () ->
    (match reject_removed_keeper_input_keys ~tool_name:"masc_keeper_msg" args with
    | Error e -> (false, "❌ " ^ e)
    | Ok () ->
    (match reject_removed_keeper_msg_input_keys ~tool_name:"masc_keeper_msg" args with
    | Error e -> (false, "❌ " ^ e)
    | Ok () ->
    match ensure_keeper_exists
      ~ctx ~name
    with
    | Error e -> (false, "❌ " ^ e)
    | Ok meta0 ->
      let turn_task_id = Printf.sprintf "keeper_turn_%s_%d"
        name (int_of_float (Time_compat.now () *. 1000.0)) in
      let turn_tracker = Progress.start_tracking ~task_id:turn_task_id ~total_steps:5 () in
      Progress.Tracker.step turn_tracker ~message:"Preparing keeper turn configuration" ();
      let meta = meta0 in
      (* start_keepalive is deferred AFTER run_turn completes.
         Starting it here causes the heartbeat fiber to immediately grab LLM
         slots, starving the synchronous run_turn call (Issue #2610). *)
      (* auto_team_session interception removed in #2908 *)
      (* === Harness: trajectory accumulator + eval gate config === *)
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:meta.runtime.trace_id
          ~generation:meta.runtime.generation
      in
      let turn_cascade_name = if direct_reply then "keeper_reply" else "keeper_turn" in
      let effective_models =
        if direct_reply then
          Oas_model_resolve.models_of_cascade_name turn_cascade_name
        else
          effective_model_labels_for_turn meta
      in
      Progress.Tracker.step turn_tracker ~message:"Validating API keys" ();
      (match ensure_api_keys_for_labels effective_models with
       | Error e ->
         Progress.stop_tracking turn_task_id;
         (false, "❌ " ^ e)
       | Ok () ->
         Progress.Tracker.step turn_tracker ~message:"Building turn prompt" ();
         let primary_max_context =
           Oas_model_resolve.resolve_primary_max_context effective_models
         in
            let base_dir = session_base_dir ctx.config in
            let effective_no_skill_route = no_skill_route || direct_reply in
            let effective_no_state_block = no_state_block || direct_reply in
            let fallback_skill_route =
              route_keeper_skill ~soul_profile:meta.soul_profile ~message
            in
            let live_worktree_change =
              if direct_reply then
                None
              else
                Worktree_live_context.capture_change_block
                  ~base_path:ctx.config.base_path ~actor_key:meta.name
            in
            let build_turn_prompt ~base_system_prompt ~messages
                : Keeper_agent_run.turn_prompt =
              (* === SOFT CONTEXT (injected via extra_system_context) === *)
              (* 1. Continuity snapshot *)
              let continuity_snapshot = latest_state_snapshot_from_messages messages in
              let continuity_text =
                let summary =
                  match continuity_snapshot with
                  | Some s -> keeper_state_snapshot_to_summary_text s
                  | None ->
                    let trimmed = String.trim meta.continuity_summary in
                    if trimmed = "" then "" else trimmed
                in
                if summary = "" || summary = "No continuity snapshot available."
                then ""
                else "Recent continuity snapshot:\n" ^ summary
              in
              (* 2. Skill route *)
              let skill_route_text =
                if effective_no_skill_route then ""
                else
                  skill_route_context_text
                    ~fallback_route:fallback_skill_route
                    ~soul_profile:meta.soul_profile
              in
              (* 3. Worktree changes *)
              let worktree_text =
                match live_worktree_change with
                | Some summary when String.trim summary <> "" -> summary
                | _ -> ""
              in
              (* 4. Turn instructions *)
              let turn_instructions_text =
                match turn_instructions with
                | None -> ""
                | Some ti ->
                  "--- Turn-specific instructions ---\n" ^ ti
              in
              let soft_parts = List.filter
                (fun s -> String.trim s <> "")
                [ skill_route_text;
                  continuity_text;
                  worktree_text;
                  turn_instructions_text ]
              in
              let dynamic_context = String.concat "\n\n" soft_parts in
              (* === HARD CONSTRAINTS (stay in system_prompt) === *)
              (* 1. Direct reply mode *)
              let prompt =
                if direct_reply then
                  Keeper_prompt.append_direct_reply_mode_prompt
                    ~base_prompt:base_system_prompt
                else
                  base_system_prompt
              in
              (* 2. Policy guards + tool-use guidance *)
              let prompt =
                let policy_guards = [
                  (effective_no_skill_route,
                   "Output guard: NEVER output lines starting with SKILL: or SKILL_REASON:.");
                  (effective_no_state_block,
                   "Output guard: NEVER output [STATE] or [/STATE] blocks in this turn.");
                ] in
                let policy_lines =
                  List.filter_map
                    (fun (active, line) -> if active then Some line else None)
                    policy_guards
                in
                let tool_use_lines = [
                  "Tool-use guidance:";
                  "- If the user asks you to speak, use voice, make sound, or output TTS, prefer keeper_voice_session_start and keeper_voice_speak.";
                  "- Do not simulate spoken audio with plain text roleplay when a voice tool can handle the request.";
                  "- If voice execution fails, say that voice output is unavailable and continue in text.";
                ] in
                match policy_lines @ tool_use_lines with
                | [] -> prompt
                | _ ->
                    Printf.sprintf "%s\n\n%s"
                      prompt
                      (String.concat "\n" (policy_lines @ tool_use_lines))
              in
              { system_prompt = prompt; dynamic_context }
            in
            Progress.Tracker.step turn_tracker
              ~message:(Printf.sprintf "Executing Agent.run for %s" name) ();
            match
              Keeper_agent_run.run_turn
                ~config:ctx.config ~meta ~base_dir
                ~max_context:primary_max_context
                ~build_turn_prompt
                ~user_message:message
                ~cascade_name:turn_cascade_name
                ~generation:meta.runtime.generation
                ?on_event
                ~trajectory_acc
                ~priority:Llm_provider.Request_priority.Interactive
                ()
            with
            | Error e ->
              (try ignore (Trajectory.finalize trajectory_acc
                 (Trajectory.Failed e))
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run error)" exn);
              start_keepalive ctx meta;
              Progress.stop_tracking turn_task_id;
              (false, Printf.sprintf "❌ Agent.run failed: %s" e)
            | Ok result ->
              (try ignore (Trajectory.finalize trajectory_acc
                 Trajectory.Completed)
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run ok)" exn);
              start_keepalive ctx meta;
              Progress.Tracker.complete turn_tracker
                ~message:(Printf.sprintf "Turn completed: %d tool calls" result.tool_calls_made) ();
              let reply_json = `Assoc [
                ("reply", `String result.response_text);
                ("model", `String result.model_used);
                ("turns", `Int result.turn_count);
                ("tool_calls", `Int result.tool_calls_made);
              ] in
              (true, Yojson.Safe.to_string reply_json)

))))
