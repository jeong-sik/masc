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
      let prompt = explicit_room_prompt ~meta ~room_id msg in
      let build_turn_prompt ~base_system_prompt ~messages:_ =
        base_system_prompt
      in
      let (run_result, latency) = Keeper_exec_context.timed (fun () ->
        Keeper_agent_run.run_turn
          ~config:ctx.config ~meta ~base_dir
          ~max_context:primary.max_context
          ~build_turn_prompt
          ~user_message:prompt
          ~cascade_name:"keeper_turn"
          ~generation:meta.generation
          ~max_turns:5
          ~temperature:(Keeper_config.keeper_reflection_temp ())
          ~max_tokens:(Keeper_config.keeper_explicit_reply_max_tokens ())
          ()
      ) in
      match run_result with
      | Error e -> Error e
      | Ok result ->
          let reply_raw = String.trim result.response_text in
          let reply =
            if reply_raw = "" then
              Printf.sprintf "@%s 야, 다시 한 번만 말해봐." msg.from_agent
            else
              reply_raw
          in
          let used_model =
            model_spec_for_used specs result.model_used
            |> Option.value ~default:primary
          in
          let now_ts = Time_compat.now () in
          let updated =
            {
              meta with
              updated_at = now_iso ();
              total_turns = meta.total_turns + 1;
              total_input_tokens = meta.total_input_tokens + result.usage.input_tokens;
              total_output_tokens = meta.total_output_tokens + result.usage.output_tokens;
              total_tokens = meta.total_tokens + Keeper_exec_context.total_tokens result.usage;
              total_cost_usd =
                meta.total_cost_usd +. cost_usd_of_usage result.usage used_model;
              last_turn_ts = now_ts;
              last_model_used = result.model_used;
              last_input_tokens = result.usage.input_tokens;
              last_output_tokens = result.usage.output_tokens;
              last_total_tokens = Keeper_exec_context.total_tokens result.usage;
              last_latency_ms = latency;
            }
          in
          Ok (updated, reply)

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
      let social_gate =
        Keeper_exec_autonomy.autonomous_gate_config
          ~autonomy_level:Keeper_autonomy.L3_Guided
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
