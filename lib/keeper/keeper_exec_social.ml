(** Keeper_exec_social — explicit room replies, social board event handling,
    learned policy room events, and mention-driven room reply emission. *)

open Keeper_types
open Keeper_memory [@@warning "-33"]
open Keeper_alerting [@@warning "-33"]
open Keeper_exec_tools [@@warning "-33"]
open Keeper_exec_context

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
            | [] -> Llm_cascade.default_local_model_spec ()
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
          let user_message = Agent_sdk.Types.user_msg prompt in
          let ctx_work = Context_manager.append ctx_work user_message in
          Context_manager.persist_message session user_message;
          let requests =
            List.map
              (fun (model : Llm_types.model_spec) ->
                ({
                  Llm_types.model;
                  messages = (Agent_sdk.Types.system_msg ctx_work.system_prompt) :: ctx_work.messages;
                  temperature = Keeper_config.keeper_reflection_temp ();
                  max_tokens = Keeper_config.keeper_explicit_reply_max_tokens ();
                  tools = [];
                  response_format = `Text;
                } : Llm_types.completion_request))
              specs
          in
          let (cascade_result, cascade_latency) = Llm_types.timed (fun () ->
              Keeper_oas_adapter.run_cascade requests) in
          match cascade_result with
          | Error e -> Error e
          | Ok resp ->
              let used_model =
                model_spec_for_used specs resp.Llm_provider.Types.model |> Option.value ~default:primary
              in
              let reply_raw = String.trim (Llm_types.text_of_response resp) in
              let reply =
                if reply_raw = "" then
                  Printf.sprintf "@%s 야, 다시 한 번만 말해봐." msg.from_agent
                else
                  reply_raw
              in
              let assistant_message = Agent_sdk.Types.assistant_msg reply in
              let ctx_work = Context_manager.append ctx_work assistant_message in
              Context_manager.persist_message session assistant_message;
              (try ignore (save_checkpoint session ctx_work ~generation:meta.generation)
               with exn ->
                 log_keeper_exn ~label:"save_checkpoint (explicit room reply) failed" exn);
              let usage = Llm_types.usage_of_response resp in
              let now_ts = Time_compat.now () in
              let updated =
                {
                  meta with
                  updated_at = now_iso ();
                  total_turns = meta.total_turns + 1;
                  total_input_tokens = meta.total_input_tokens + usage.input_tokens;
                  total_output_tokens = meta.total_output_tokens + usage.output_tokens;
                  total_tokens = meta.total_tokens + Llm_types.total_tokens usage;
                  total_cost_usd =
                    meta.total_cost_usd +. cost_usd_of_usage usage used_model;
                  last_turn_ts = now_ts;
                  last_model_used = resp.Llm_provider.Types.model;
                  last_input_tokens = usage.input_tokens;
                  last_output_tokens = usage.output_tokens;
                  last_total_tokens = Llm_types.total_tokens usage;
                  last_latency_ms = cascade_latency;
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
            | [] -> Llm_cascade.default_local_model_spec ()
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
          let user_message = Agent_sdk.Types.user_msg prompt in
          let ctx_work = Context_manager.append ctx_work user_message in
          Context_manager.persist_message session user_message;
          (* Social context: L3-equivalent guardrails (read + board tools) *)
          let social_gate =
            Keeper_exec_autonomy.autonomous_gate_config
              ~autonomy_level:Keeper_autonomy.L3_Guided
          in
          let guardrails =
            Verifier_oas.eval_gate_to_oas_guardrails social_gate
          in
          let max_tool_rounds = Keeper_config.keeper_max_tool_rounds () in
          let system_prompt = ctx_work.system_prompt in
          let goal = prompt in
          let (oas_result, total_latency_ms) = Llm_types.timed (fun () ->
              Keeper_oas_adapter.run_with_tools
                ~config:ctx.config ~meta
                ~cascade_name:"keeper_social"
                ~system_prompt ~goal
                ~max_turns:max_tool_rounds
                ~temperature:(Keeper_config.keeper_planning_temp ())
                ~max_tokens:(Keeper_config.keeper_social_initial_max_tokens ())
                ~guardrails ())
          in
          match oas_result with
          | Error e -> Error e
          | Ok { Keeper_oas_adapter.oas_result = run_result;
                 Keeper_oas_adapter.tools_executed = final_tools_used } ->
              let final_resp = run_result.Oas_worker.response in
              let final_content =
                let trimmed = String.trim (Llm_types.text_of_response final_resp) in
                if trimmed = "" && final_tools_used <> [] then
                  Printf.sprintf "(tools executed: %s)" (String.concat ", " final_tools_used)
                else if trimmed = "" then trimmed
                else trimmed
              in
              let final_usage = Llm_types.usage_of_response final_resp in
              let final_model_used = final_resp.Llm_provider.Types.model in
              let final_latency_ms = total_latency_ms in
              let final_cost_usd =
                let used_model = model_spec_for_used specs final_model_used
                  |> Option.value ~default:primary in
                cost_usd_of_usage final_usage used_model
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
              let assistant_message = Agent_sdk.Types.assistant_msg assistant_text in
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
                  total_tokens = meta.total_tokens + Llm_types.total_tokens final_usage;
                  total_cost_usd = meta.total_cost_usd +. final_cost_usd;
                  last_turn_ts = now_ts;
                  last_model_used = final_model_used;
                  last_input_tokens = final_usage.input_tokens;
                  last_output_tokens = final_usage.output_tokens;
                  last_total_tokens = Llm_types.total_tokens final_usage;
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
