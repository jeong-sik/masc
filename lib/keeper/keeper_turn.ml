(** Keeper_turn -- keeper lifecycle and message-turn handlers.

    Orchestrates keeper turns by building domain-specific system prompt
    configuration and delegating to {!Keeper_agent_run.run_turn} which
    owns the full context lifecycle (checkpoint, Context_manager, Agent.run).

    Sub-modules:
    - Keeper_turn_up: start/reconfigure
    - Keeper_turn_session: team-session integration
    - Keeper_turn_response: turn_env type, JSON builders, finalize
    - Keeper_turn_setup: ensure_keeper_exists, apply_settings_update
    - Keeper_turn_lifecycle: model-set, shutdown *)

open Tool_args
open Keeper_types
open Keeper_memory [@@warning "-33"]
open Keeper_alerting [@@warning "-33"]
open Keeper_exec_tools [@@warning "-33"]
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_session
open Keeper_turn_response [@@warning "-33"]
open Keeper_turn_setup

type tool_result = Keeper_types.tool_result

let handle_keeper_up = Keeper_turn_up.handle_keeper_up
let handle_keeper_model_set = Keeper_turn_lifecycle.handle_keeper_model_set
let handle_keeper_down = Keeper_turn_lifecycle.handle_keeper_down

(* -- handle_keeper_msg: orchestrator ---------------------------------------- *)

let handle_keeper_msg ?on_text_delta ctx args : tool_result =
  ignore on_text_delta; (* streaming not yet wired to Agent.run() *)
  let name = get_string args "name" "" in
  let message = get_string args "message" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if message = "" then
    (false, "❌ message is required")
  else
    let profile_defaults = load_keeper_profile_defaults name in
    let inline_goal = get_string_opt args "goal" in
    let inline_short_goal = parse_goal_horizon_opt args "short_goal" in
    let inline_mid_goal = parse_goal_horizon_opt args "mid_goal" in
    let inline_long_goal = parse_goal_horizon_opt args "long_goal" in
    let inline_instructions = get_string_opt args "instructions" in
    let turn_instructions = get_string_opt args "turn_instructions" in
    let no_skill_route = get_bool args "no_skill_route" false in
    let no_state_block = get_bool args "no_state_block" false in
    let inline_will = parse_self_model_opt args "will" in
    let inline_needs = parse_self_model_opt args "needs" in
    let inline_desires = parse_self_model_opt args "desires" in
    let inline_drift_enabled_opt = get_bool_opt args "drift_enabled" in
    let inline_drift_min_turn_gap_opt = Safe_ops.json_int_opt "drift_min_turn_gap" args in
    let inline_soul_profile_res = parse_soul_profile_opt args "soul_profile" in
    let new_soul_profile_res = parse_soul_profile_opt args "new_soul_profile" in
    let new_short_goal = parse_goal_horizon_opt args "new_short_goal" in
    let new_mid_goal = parse_goal_horizon_opt args "new_mid_goal" in
    let new_long_goal = parse_goal_horizon_opt args "new_long_goal" in
    let new_will = parse_self_model_opt args "new_will" in
    let new_needs = parse_self_model_opt args "new_needs" in
    let new_desires = parse_self_model_opt args "new_desires" in
    let new_drift_enabled_opt = get_bool_opt args "new_drift_enabled" in
    let new_drift_min_turn_gap_opt = Safe_ops.json_int_opt "new_drift_min_turn_gap" args in
    let inline_models = get_string_list args "models" in
    let require_existing = get_bool args "require_existing" false in
    match inline_soul_profile_res, new_soul_profile_res with
    | Error e, _ | _, Error e -> (false, "❌ " ^ e)
    | Ok inline_soul_profile, Ok new_soul_profile ->
    match ensure_keeper_exists
      ~ctx ~name ~require_existing ~profile_defaults
      ~inline_goal ~inline_short_goal ~inline_mid_goal ~inline_long_goal
      ~inline_instructions ~inline_will ~inline_needs ~inline_desires
      ~inline_drift_enabled_opt ~inline_drift_min_turn_gap_opt
      ~inline_soul_profile ~inline_models
    with
    | Error e -> (false, "❌ " ^ e)
    | Ok meta0 ->
      let meta =
        apply_settings_update
          ~args ~meta0 ~new_short_goal ~new_mid_goal ~new_long_goal
          ~new_soul_profile ~new_will ~new_needs ~new_desires
          ~new_drift_enabled_opt ~new_drift_min_turn_gap_opt
          ~config:ctx.config
      in
      start_keepalive ctx meta;
      match maybe_handle_auto_team_session ctx meta message with
      | Error err -> (false, "❌ " ^ err)
      | Ok (Some result, _) -> result
      | Ok (None, meta) ->
      (* === Harness: trajectory accumulator + eval gate config === *)
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:meta.trace_id
          ~generation:meta.generation
      in
      let effective_models =
        effective_model_labels_for_turn meta ~inline_models
      in
      let effective_models =
        if
          (meta.trigger_mode
           |> Keeper_contract.trigger_mode_of_string
           |> Keeper_contract.trigger_mode_is_explicit_only)
          || keeper_policy_mode_is_learned meta
        then
          effective_models
        else maybe_append_keeper_fallback_models effective_models
      in
      (match ensure_api_keys_for_labels effective_models with
       | Error e -> (false, "❌ " ^ e)
       | Ok () ->
         let specs = Cascade.available_model_specs_of_strings effective_models in
         let primary = match specs with m0 :: _ -> m0 | [] -> Cascade.default_local_model_spec () in
            let base_dir = session_base_dir ctx.config in
            let policy_mode_learned = keeper_policy_mode_is_learned meta in
            let effective_no_skill_route = no_skill_route || policy_mode_learned in
            let fallback_skill_route =
              if policy_mode_learned then
                {
                  primary_skill = "policy";
                  secondary_skills = [];
                  reason = "learned_offline_v1";
                }
              else
                route_keeper_skill ~soul_profile:meta.soul_profile ~message
            in
            let skill_selection_mode =
              if policy_mode_learned then SkillSelectHeuristic
              else keeper_skill_selection_mode ()
            in
            let build_turn_prompt ~base_system_prompt ~messages =
              let continuity_snapshot = latest_state_snapshot_from_messages messages in
              let continuity_summary =
                match continuity_snapshot with
                | Some s -> keeper_state_snapshot_to_summary_text s
                | None ->
                  let trimmed = String.trim meta.continuity_summary in
                  if trimmed = "" then "No continuity snapshot available." else trimmed
              in
              let base_turn_system_prompt =
                if effective_no_skill_route then
                  base_system_prompt
                else
                  match skill_selection_mode with
                  | SkillSelectHeuristic ->
                      skill_route_system_prompt_heuristic
                        ~base_system_prompt
                        ~route:fallback_skill_route
                  | SkillSelectAgent ->
                      skill_route_system_prompt_agent
                        ~base_system_prompt
                        ~fallback_route:fallback_skill_route
                        ~soul_profile:meta.soul_profile
              in
              let prompt =
                append_continuity_context_prompt
                  ~base_prompt:base_turn_system_prompt
                  continuity_snapshot
                  ~continuity_summary
              in
              let prompt =
                let policy_guards = [
                  (effective_no_skill_route,
                   "Output guard: NEVER output lines starting with SKILL: or SKILL_REASON:.");
                  (no_state_block,
                   "Output guard: NEVER output [STATE] or [/STATE] blocks in this turn.");
                ] in
                let policy_lines =
                  List.filter_map
                    (fun (active, line) -> if active then Some line else None)
                    policy_guards
                in
                match policy_lines with
                | [] -> prompt
                | _ ->
                    Printf.sprintf "%s\n\n%s"
                      prompt
                      (String.concat "\n" policy_lines)
              in
              match turn_instructions with
              | None -> prompt
              | Some ti ->
                  Printf.sprintf "%s\n\n--- Turn-specific instructions ---\n%s"
                    prompt ti
            in
            match
              Keeper_agent_run.run_turn
                ~config:ctx.config ~meta ~base_dir
                ~max_context:primary.max_context
                ~build_turn_prompt
                ~user_message:message
                ~cascade_name:"keeper_turn"
                ~generation:meta.generation ()
            with
            | Error e ->
              (try ignore (Trajectory.finalize trajectory_acc
                 (Trajectory.Failed e))
               with exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run error)" exn);
              (false, Printf.sprintf "❌ Agent.run failed: %s" e)
            | Ok result ->
              (try ignore (Trajectory.finalize trajectory_acc
                 Trajectory.Completed)
               with exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run ok)" exn);
              let reply_json = `Assoc [
                ("reply", `String result.response_text);
                ("model", `String result.model_used);
                ("turns", `Int result.turn_count);
                ("tool_calls", `Int result.tool_calls_made);
              ] in
              (true, Yojson.Safe.to_string reply_json)

)
