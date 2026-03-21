(** Keeper_exec_social — social board event handling.

    Mention-driven room replies and proactive emission are now handled by the
    unified keeper turn path (Keeper_unified_turn). Only the board event turn
    remains here as it is called independently from social_runtime.ml.

    @since Unified Keeper Loop — legacy functions removed *)

open Keeper_types
open Keeper_memory [@@warning "-33"]
open Keeper_exec_context

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
  let relationship_hint =
    match event.kind, event.post_author with
    | `Board_comment, Some pa when pa = meta.name ->
        Printf.sprintf
          "\nRelationship: This comment is on YOUR post. Someone is engaging with you directly. \
           You should usually respond unless the comment is trivial."
    | `Board_comment, Some pa ->
        Printf.sprintf "\nOriginal post author: %s" pa
    | `Board_post, _ when event.author = meta.name ->
        "\nRelationship: This is your own post. Skip."
    | _ -> ""
  in
  Printf.sprintf
    "You are resident keeper %s acting in the room's public square.\n\
     A new board event requires triage.\n\n\
     Event type: %s\n\
     Post ID: %s%s\n\
     Author: %s%s\n\
     Content preview:\n%s\n\n\
     If you act, use tools directly.\n\
     Read the full thread with `keeper_board_get` before deciding whenever context is incomplete.\n\
     Preferred action order:\n\
     1. `keeper_board_comment` when a direct reply is sufficient.\n\
     2. `keeper_board_vote` when a lightweight signal is enough.\n\
     3. `keeper_board_post` only for broader escalation or synthesis.\n\
     If no action is warranted, explain briefly why you passed.\n\
     Never respond to events you authored yourself.\n\
     Stay in character and keep any final text concise."
    meta.name
    event_kind
    event.post_id
    comment_hint
    event.author
    relationship_hint
    event.content

let run_social_board_event_turn
    (ctx : _ context)
    ~(meta : keeper_meta)
    ~(event : social_board_event) : (keeper_meta * social_turn_outcome, string) result =
  let model_labels = effective_model_labels_for_turn meta ~inline_models:[] in
  match ensure_api_keys_for_labels model_labels with
  | Error e -> Error e
  | Ok () ->
      let specs = Model_spec.available_model_specs_of_strings model_labels in
      let primary =
        match specs with
        | model :: _ -> model
        | [] -> Model_spec.default_local_model_spec ()
      in
      let base_dir = session_base_dir ctx.config in
      let prompt = social_board_event_prompt ~meta event in
      (* Social context: L3-equivalent guardrails (read + board tools) *)
      let social_gate : Eval_gate.gate_config =
        {
          max_cost_usd = 0.10;
          max_tool_calls_per_turn = 5;
          entropy_threshold = 2;
          destructive_check_enabled = true;
          allowlist_enabled = true;
          allowed_tools = [
            "keeper_board_get"; "keeper_board_post"; "keeper_board_comment";
            "keeper_board_vote"; "keeper_board_list";
            "keeper_read"; "keeper_fs_read";
            "keeper_memory_search";
            "keeper_time_now"; "keeper_context_status";
          ];
          denied_tools = [
            "keeper_bash"; "keeper_edit"; "keeper_fs_edit"; "keeper_github";
          ];
        }
      in
      let guardrails =
        Verifier_oas.eval_gate_to_oas_guardrails social_gate
      in
      let max_tool_rounds = Keeper_config.keeper_max_tool_rounds () in
      let build_turn_prompt ~base_system_prompt ~messages:_ =
        base_system_prompt
      in
      let (run_result, total_latency_ms) = Keeper_exec_context.timed (fun () ->
        Keeper_agent_run.run_turn
          ~config:ctx.config ~meta ~base_dir
          ~max_context:primary.max_context
          ~build_turn_prompt
          ~user_message:prompt
          ~cascade_name:"keeper_social"
          ~generation:meta.generation
          ~max_turns:max_tool_rounds
          ~guardrails
          ~temperature:(Keeper_config.keeper_planning_temp ())
          ~max_tokens:(Keeper_config.keeper_social_initial_max_tokens ())
          ()
      ) in
      match run_result with
      | Error e -> Error e
      | Ok result ->
          let final_tools_used = result.tools_used in
          let final_content =
            let trimmed = String.trim result.response_text in
            if trimmed = "" && final_tools_used <> [] then
              Printf.sprintf "(tools executed: %s)" (String.concat ", " final_tools_used)
            else if trimmed = "" then trimmed
            else trimmed
          in
          let final_cost_usd =
            let used_model = model_spec_for_used specs result.model_used
              |> Option.value ~default:primary in
            cost_usd_of_usage result.usage used_model
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
              total_input_tokens = meta.total_input_tokens + result.usage.input_tokens;
              total_output_tokens = meta.total_output_tokens + result.usage.output_tokens;
              total_tokens = meta.total_tokens + Keeper_exec_context.total_tokens result.usage;
              total_cost_usd = meta.total_cost_usd +. final_cost_usd;
              last_turn_ts = now_ts;
              last_model_used = result.model_used;
              last_input_tokens = result.usage.input_tokens;
              last_output_tokens = result.usage.output_tokens;
              last_total_tokens = Keeper_exec_context.total_tokens result.usage;
              last_latency_ms = total_latency_ms;
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
              } )
