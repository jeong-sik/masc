(** Keeper_exec_proactive — deliberation dispatch, autonomous goal turn dispatch,
    proactive emission loop (maybe_emit_proactive). *)

open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_exec_context
open Keeper_exec_autonomy

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
      (* Phase 2 Deliberation Engine: if policy_mode is Model_deliberation AND
         triage returned Triggered, call the MODEL deliberation engine instead
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
          Log.KeeperExec.info "%s budget exhausted (%.4f >= %.4f)"
            meta.name meta.deliberation_cost_total_usd daily_budget;
          meta)
        else
          match ensure_api_keys_for_labels meta.models with
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
                    Log.KeeperExec.info "%s no parseable triggers from: %s"
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
                       with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                         Log.Keeper.warn "proactive: task count query failed: %s" (Printexc.to_string exn);
                         (0, 0))
                    in
                    let active_agents =
                      (try List.length (Room.get_agents_raw ctx.config)
                       with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                         Log.Keeper.warn "proactive: agent count query failed: %s" (Printexc.to_string exn);
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
                    let system =
                      "You are " ^ meta.name
                      ^ ", a keeper agent. Respond with JSON only."
                    in
                    (* model_specs retained for cost estimation only *)
                    let model_specs =
                      Model_spec.available_model_specs_of_strings meta.models
                    in
                    let base_dir = session_base_dir ctx.config in
                    let build_turn_prompt ~base_system_prompt:_ ~messages:_ =
                      system
                    in
                    let max_ctx =
                      match model_specs with p :: _ -> p.max_context | [] -> 4096
                    in
                    let (delib_result, delib_latency) = Keeper_exec_context.timed (fun () ->
                      Keeper_agent_run.run_turn
                        ~config:ctx.config ~meta ~base_dir
                        ~max_context:max_ctx
                        ~build_turn_prompt
                        ~user_message:prompt
                        ~cascade_name:"keeper_proactive"
                        ~generation:meta.generation
                        ~max_turns:5
                        ~temperature:0.3
                        ~max_tokens:1024 ()) in
                    match delib_result with
                    | Error msg ->
                        Log.KeeperExec.error "%s MODEL call failed: %s"
                          meta.name msg;
                        meta
                    | Ok result ->
                        let response_usage = result.Keeper_agent_run.usage in
                        let turn_cost =
                          let inp =
                            float_of_int response_usage.input_tokens /. 1000.0
                          in
                          let outp =
                            float_of_int response_usage.output_tokens /. 1000.0
                          in
                          let primary =
                            match model_specs with
                            | p :: _ -> p
                            | [] -> Model_spec.default_local_model_spec ()
                          in
                          (inp *. primary.cost_per_1k_input)
                          +. (outp *. primary.cost_per_1k_output)
                        in
                        (match
                           Keeper_deliberation.parse_deliberation_response
                             (result.Keeper_agent_run.response_text)
                         with
                         | Error msg ->
                             Log.KeeperExec.error "%s parse failed: %s (raw: %s)"
                               meta.name msg
                               (Keeper_types.short_preview (result.Keeper_agent_run.response_text));
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
                                  Log.KeeperExec.error "write_meta failed: %s"
                                    msg);
                             updated
                         | Ok (action, reasoning, confidence) ->
                             Log.KeeperExec.info "%s decided: %s (confidence=%.2f, reason=%s)"
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
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
                                     log_keeper_exn ~label:"deliberation reply_in_room failed" exn)
                              | Keeper_deliberation.Broadcast { message } ->
                                  (try
                                     ignore
                                       (Room.broadcast ctx.config
                                          ~from_agent:meta.agent_name
                                          ~content:message)
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
                                     log_keeper_exn ~label:"deliberation broadcast failed" exn)
                              | Keeper_deliberation.TaskClaim { task_id; reason = _ } ->
                                  (try
                                     let result =
                                       Room.claim_task ctx.config
                                         ~agent_name:meta.agent_name
                                         ~task_id
                                     in
                                     Log.KeeperExec.info "task_claim result: %s"
                                       result
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
                                     log_keeper_exn ~label:"deliberation task_claim failed" exn)
                              | Keeper_deliberation.BoardPost { content; hearth } ->
                                  (try
                                     ignore
                                       (Board_dispatch.create_post
                                          ~author:meta.agent_name
                                          ~content
                                          ?hearth
                                          ())
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
                                     log_keeper_exn ~label:"deliberation board_post failed" exn)
                              | Keeper_deliberation.BoardComment { post_id; content } ->
                                  (try
                                     ignore
                                       (Board_dispatch.add_comment
                                          ~post_id
                                          ~author:meta.agent_name
                                          ~content
                                          ())
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
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
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
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
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
                                     log_keeper_exn ~label:"deliberation propose_spawn failed" exn)
                              | Keeper_deliberation.StartDiscussion { topic; context } ->
                                  (try
                                     let msg =
                                       Printf.sprintf
                                         "[discussion] %s opens topic '%s': %s"
                                         meta.name topic context
                                     in
                                     ignore
                                       (Room.broadcast ctx.config
                                          ~from_agent:meta.agent_name
                                          ~content:msg)
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
                                     log_keeper_exn ~label:"deliberation start_discussion failed" exn)
                              | Keeper_deliberation.ShareFinding { finding; source } ->
                                  (try
                                     let msg =
                                       Printf.sprintf
                                         "[finding] %s shares from %s: %s"
                                         meta.name source finding
                                     in
                                     ignore
                                       (Room.broadcast ctx.config
                                          ~from_agent:meta.agent_name
                                          ~content:msg)
                                   with
                                   | Eio.Cancel.Cancelled _ as e -> raise e
                                   | exn ->
                                     log_keeper_exn ~label:"deliberation share_finding failed" exn)
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
                                        Log.KeeperExec.info "%s multi_step %d/%d: %s"
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
                                           | Keeper_deliberation.StartDiscussion { topic; context } ->
                                               let msg =
                                                 Printf.sprintf
                                                   "[discussion] %s opens topic '%s': %s"
                                                   meta.name topic context
                                               in
                                               ignore
                                                 (Room.broadcast ctx.config
                                                    ~from_agent:meta.agent_name
                                                    ~content:msg)
                                           | Keeper_deliberation.ShareFinding { finding; source } ->
                                               let msg =
                                                 Printf.sprintf
                                                   "[finding] %s shares from %s: %s"
                                                   meta.name source finding
                                               in
                                               ignore
                                                 (Room.broadcast ctx.config
                                                    ~from_agent:meta.agent_name
                                                    ~content:msg)
                                           | Keeper_deliberation.MultiStep _ ->
                                               Log.KeeperExec.info "%s nested multi_step skipped"
                                                 meta.name
                                         with
                                         | Eio.Cancel.Cancelled _ as e -> raise e
                                         | exn ->
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
                                   + response_usage.input_tokens;
                                 total_output_tokens =
                                   meta.total_output_tokens
                                   + response_usage.output_tokens;
                                 total_tokens =
                                   meta.total_tokens
                                   + Keeper_exec_context.total_tokens response_usage;
                                 total_cost_usd =
                                   meta.total_cost_usd +. turn_cost;
                                 last_turn_ts = now_ts;
                                 last_model_used = result.Keeper_agent_run.model_used;
                                 last_input_tokens =
                                   response_usage.input_tokens;
                                 last_output_tokens =
                                   response_usage.output_tokens;
                                 last_total_tokens =
                                   Keeper_exec_context.total_tokens response_usage;
                                 last_latency_ms = delib_latency;
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
                                  Log.KeeperExec.error "write_meta failed: %s"
                                    msg);
                             updated))
      else
      match ensure_api_keys_for_labels meta.models with
      | Error msg ->
          log_proactive_failure ("api keys: " ^ msg);
          meta
      | Ok () ->
          let specs = Model_spec.available_model_specs_of_strings meta.models in
          (match specs with
           | [] ->
               log_proactive_failure "no available model specs";
               meta
           | _ ->
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
                 | [] -> Model_spec.default_local_model_spec ()
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
	                       let assistant_msg = Agent_sdk.Types.assistant_msg safe_reply in
	                       let ctx_work = Context_manager.append ctx_work assistant_msg in
                       Context_manager.persist_message session assistant_msg;
                       let before_compact_tokens = ctx_work.token_count in
                       let (ctx_work, compaction_trigger, compaction_decision) =
                        compact_if_needed ~meta:meta_for_compaction ~now_ts ctx_work
                       in
                       let after_compact_tokens = ctx_work.token_count in
                       let compacted = after_compact_tokens < before_compact_tokens in
                       (try ignore (save_checkpoint session ctx_work ~generation:meta.generation)
                        with
                        | Eio.Cancel.Cancelled _ as e -> raise e
                        | exn -> log_keeper_exn ~label:"save_checkpoint (tool_loop) failed" exn);
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
                           total_tokens = meta.total_tokens + Keeper_exec_context.total_tokens generated.usage;
                           total_cost_usd = meta.total_cost_usd +. turn_cost;
                           last_turn_ts = now_ts;
                           last_model_used = model_used;
                           last_input_tokens = generated.usage.input_tokens;
                           last_output_tokens = generated.usage.output_tokens;
                           last_total_tokens = Keeper_exec_context.total_tokens generated.usage;
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
                                ("model_backend", `String "oas");
                                ( "usage",
                                  `Assoc
                                    [
                                      ("input_tokens", `Int generated.usage.input_tokens);
                                      ("output_tokens", `Int generated.usage.output_tokens);
                                      ("total_tokens", `Int (Keeper_exec_context.total_tokens generated.usage));
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
                       with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                         log_keeper_exn ~label:"metrics JSONL write failed" exn);
                       updated))

