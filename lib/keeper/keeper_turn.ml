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
open Keeper_memory
open Keeper_alerting
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_setup

type tool_result = Keeper_types.tool_result

let handle_keeper_up = Keeper_turn_up.handle_keeper_up
let handle_keeper_down = Keeper_turn_lifecycle.handle_keeper_down

let resolved_model_id_for_result ~(meta : keeper_meta)
    (result : Keeper_agent_run.run_result) : string =
  let strip_latest s =
    if String.length s > 7 && String.sub s (String.length s - 7) 7 = ":latest"
    then String.sub s 0 (String.length s - 7)
    else s
  in
  let used = strip_latest result.model_used in
  let cascade_models =
    Keeper_model_labels.configured_model_labels_of_meta meta
  in
  let cfgs = Cascade_config.parse_model_strings cascade_models in
  match
    List.find_opt
      (fun (c : Llm_provider.Provider_config.t) ->
        c.model_id = result.model_used || c.model_id = used)
      cfgs
  with
  | Some c -> c.model_id
  | None -> (match cfgs with c :: _ -> c.model_id | [] -> result.model_used)

let turn_cost_for_result ~(meta : keeper_meta)
    (result : Keeper_agent_run.run_result) : float =
  let pricing =
    Llm_provider.Pricing.pricing_for_model
      (resolved_model_id_for_result ~meta result)
  in
  Llm_provider.Pricing.estimate_cost ~pricing
    ~input_tokens:result.usage.input_tokens
    ~output_tokens:result.usage.output_tokens ()

let update_direct_turn_meta (meta : keeper_meta) ~(latency_ms : int)
    (result : Keeper_agent_run.run_result) : keeper_meta =
  let now_ts = Time_compat.now () in
  let turn_cost = turn_cost_for_result ~meta result in
  let surface_model_used = Keeper_agent_run.surface_model_used result in
  {
    meta with
    updated_at = now_iso ();
    runtime =
      {
        meta.runtime with
        usage =
          {
            total_turns = meta.runtime.usage.total_turns + 1;
            total_input_tokens =
              meta.runtime.usage.total_input_tokens + result.usage.input_tokens;
            total_output_tokens =
              meta.runtime.usage.total_output_tokens + result.usage.output_tokens;
            total_tokens =
              meta.runtime.usage.total_tokens
              + Keeper_exec_context.total_tokens result.usage;
            total_cost_usd = meta.runtime.usage.total_cost_usd +. turn_cost;
            last_turn_ts = now_ts;
            last_model_used = surface_model_used;
            last_input_tokens = result.usage.input_tokens;
            last_output_tokens = result.usage.output_tokens;
            last_total_tokens =
              Keeper_exec_context.total_tokens result.usage;
            last_latency_ms = latency_ms;
          };
      };
  }

let direct_turn_observation (meta : keeper_meta) :
    Keeper_world_observation.world_observation =
  {
    pending_mentions = [];
    pending_board_events = [];
    pending_scope_messages = [];
    message_cursor_updates = [];
    idle_seconds = 0;
    active_goals = meta.active_goal_ids;
    continuity_summary = meta.continuity_summary;
    worktree_change_summary = None;
    context_ratio = 0.0;
    economic_pressure = Agent_economy.Normal;
    unclaimed_task_count = 0;
    failed_task_count = 0;
    pending_verification_count = 0;
    backlog_updated_since_last_scheduled_autonomous = false;
    active_agent_count = 0;
    last_turn_budget = None;
    last_tools_used = [];
    work_discovery_due = false;
  }

let resolve_turn_cascade_name (meta : keeper_meta) =
  let raw_name = String.trim meta.cascade_name in
  match Cascade_catalog_runtime.resolve_declared_name ~raw_name () with
  | Ok cascade_name -> Ok cascade_name
  | Error detail ->
      Error
        (Printf.sprintf
           "invalid cascade_name %S for keeper %s: %s"
           raw_name meta.name detail)

(* -- handle_keeper_msg: orchestrator ---------------------------------------- *)

let handle_keeper_msg ?on_text_delta ctx args : tool_result =
  let on_event = match on_text_delta with
    | None -> None
    | Some cb -> Some (fun (evt : Oas.Types.sse_event) ->
        match evt with
        | Oas.Types.ContentBlockDelta { delta = TextDelta text; _ } -> cb text
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
    let channel_session_key = get_string_opt args "channel_session_key" in
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
      match resolve_turn_cascade_name meta with
      | Error e ->
        Progress.stop_tracking turn_task_id;
        (false, "❌ " ^ e)
      | Ok turn_cascade_name ->
      (* start_keepalive is deferred AFTER run_turn completes.
         Starting it here causes the heartbeat fiber to immediately grab LLM
         slots, starving the synchronous run_turn call (Issue #2610). *)
      (* auto execution session interception removed in #2908 *)
      (* === Harness: trajectory accumulator + eval gate config === *)
      let masc_root = Coord.masc_root_dir ctx.config in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~generation:meta.runtime.generation
      in
      let effective_models =
        if direct_reply then
          Cascade_runtime.models_of_cascade_name turn_cascade_name
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
         ignore (Cascade_runtime.refresh_local_discovery_if_possible effective_models);
         let max_cascade_context =
           let resolution =
             Keeper_exec_context.resolve_max_context_resolution
               ~requested_override:meta.max_context_override effective_models
           in
            (match resolution.requested_override with
            | Some requested ->
              Log.Keeper.debug
                "%s: using max_context_override=%d context_budget=%d primary_budget=%d effective_budget=%d (manual turn)"
                meta.name requested resolution.turn_budget resolution.primary_budget
                resolution.effective_budget
            | None -> ());
           resolution.turn_budget
         in
            let base_dir =
              let root = session_base_dir ctx.config in
              match channel_session_key with
              | Some key when direct_reply ->
                let d = Filename.concat (Filename.concat root "channels") key in
                Keeper_types.mkdir_p d; d
              | _ -> root
            in
            let effective_no_skill_route = no_skill_route || direct_reply in
            let effective_no_state_block = no_state_block || direct_reply in
            let fallback_skill_route =
              route_keeper_skill  ~message
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
              (* 1. Recovery + tiered memory context *)
              let continuity_snapshot = latest_state_snapshot_from_messages messages in
              let progress_cache =
                Keeper_memory_policy.read_progress_snapshot_cache
                  ~config:ctx.config ~name:meta.name
              in
              let recovery_snapshot, recovery_generation, recovery_source =
                match
                  progress_cache
                with
                | Some cache ->
                    (Some cache.snapshot, cache.generation, "progress_log")
                | None ->
                    (match continuity_snapshot with
                     | Some snapshot -> (Some snapshot, Some meta.runtime.generation, "checkpoint")
                     | None ->
                         (match
                            Keeper_memory_policy.state_snapshot_of_summary_text
                              meta.continuity_summary
                          with
                          | Some snapshot ->
                              (Some snapshot, None, "meta_summary")
                          | None -> (None, None, "none")))
              in
              let continuity_text =
                let recovery_sections =
                  match recovery_snapshot with
                  | None -> []
                  | Some snapshot ->
                      Keeper_memory_policy.prompt_memory_sections_of_snapshot
                        ~current_generation:meta.runtime.generation
                        ?source_generation:recovery_generation
                        snapshot
                in
                let durable_memory =
                  read_recent_memory_texts ctx.config
                    ~name:meta.name
                    ~horizon:Keeper_memory_policy.long_term_horizon
                    ~max_bytes:(128 * 1024)
                    ~max_lines:200
                    ~limit:3
                in
                let durable_text =
                  match durable_memory with
                  | [] -> ""
                  | items ->
                      "Long-term memory:\n- "
                      ^ String.concat "\n- " (List.map String.trim items)
                in
                let recovery_fallback =
                  if recovery_sections <> [] then []
                  else
                    let summary =
                      match continuity_snapshot with
                      | Some s -> keeper_state_snapshot_to_summary_text s
                      | None ->
                          continuity_fallback_summary_text
                            ~continuity_summary:meta.continuity_summary
                            ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts
                    in
                    if summary = "" || summary = "No continuity snapshot available."
                    then []
                    else [ summary ]
                in
                let blocks =
                  (if recovery_sections = [] then recovery_fallback else recovery_sections)
                  @ (if String.trim durable_text = "" then [] else [ durable_text ])
                in
                match blocks with
                | [] -> ""
                | _ ->
                    Printf.sprintf
                      "Recent continuity snapshot (%s):\n%s"
                      recovery_source
                      (String.concat "\n\n" blocks)
              in
              (* 2. Skill route *)
              let skill_route_text =
                if effective_no_skill_route then ""
                else
                  skill_route_context_text
                    ~fallback_route:fallback_skill_route
                    
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
                [ continuity_text;
                  skill_route_text;
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
            let run_result, latency_ms =
              Keeper_exec_context.timed (fun () ->
                  Keeper_agent_run.run_turn
                    ~config:ctx.config ~meta ~base_dir
                    ~max_context:max_cascade_context
                    ~build_turn_prompt
                    ~user_message:message
                    ~cascade_name:turn_cascade_name
                    ?provider_filter:(Env_config_keeper.KeeperCascade.provider_allowlist ())
                    ~generation:meta.runtime.generation
                    ?on_event
                    ~trajectory_acc
                    ?event_bus:(Keeper_event_bus.get ())
                    ())
            in
            match run_result with
            | Error err ->
              let e_str = Oas.Error.to_string err in
              (try
                 let _ = Trajectory.finalize trajectory_acc
                   (Trajectory.Failed e_str) in
                 ()
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run error)" exn);
              start_keepalive ctx meta;
              Progress.stop_tracking turn_task_id;
              (false, Printf.sprintf "❌ Agent.run failed: %s" e_str)
            | Ok result ->
              let explicit_accountability_claim =
                Keeper_social_model.extract_accountability_claim result
              in
              (try
                 let _ = Trajectory.finalize trajectory_acc
                   Trajectory.Completed in
                 ()
               with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn
                 ~label:"trajectory finalize (agent_run ok)" exn);
              let lifecycle =
                Keeper_exec_context.apply_post_turn_lifecycle ~base_dir
                  ~on_compaction_started:(fun () ->
                    Keeper_exec_context.dispatch_keeper_phase_event
                      ~config:ctx.config
                      ~keeper_name:meta.name
                      Keeper_state_machine.Compaction_started)
                  ~on_handoff_started:(fun () ->
                    Keeper_exec_context.dispatch_keeper_phase_event
                      ~config:ctx.config
                      ~keeper_name:meta.name
                      Keeper_state_machine.Handoff_started)
                  ~meta
                  ~model:result.model_used
                  ~primary_model_max_tokens:max_cascade_context
                  ~current_turn_overflow_blocker:None
                  ~checkpoint:result.checkpoint
              in
              Keeper_exec_context.dispatch_post_turn_lifecycle_events
                ~config:ctx.config
                ~keeper_name:meta.name
                lifecycle;
              let updated_meta =
                update_direct_turn_meta lifecycle.updated_meta ~latency_ms result
              in
              (match write_meta ctx.config updated_meta with
               | Ok () -> ()
               | Error msg ->
                   Log.Keeper.error "write_meta failed after keeper_msg turn: %s" msg);
              (try
                 Keeper_unified_metrics.append_metrics_snapshot
                   ~config:ctx.config
                   ~meta:updated_meta
                   ~observation:(direct_turn_observation updated_meta)
                   ~result
                   ~latency_ms
                   ~turn_cost:(turn_cost_for_result ~meta:updated_meta result)
                   ~turn_generation:lifecycle.turn_generation
                   ~channel:"turn"
                   ~snapshot_source:"keeper_turn_msg"
                   ~context_ratio:lifecycle.context_ratio
                   ~context_tokens:lifecycle.context_tokens
                   ~context_max:lifecycle.context_max
                   ~message_count:lifecycle.message_count
                   ~compaction:lifecycle.compaction
                   ~handoff_json:lifecycle.handoff_json
                   ()
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                   Log.Keeper.error
                     "write metrics snapshot failed after keeper_msg turn: %s"
                     (Printexc.to_string exn));
              Keeper_unified_metrics.broadcast_lifecycle_events
                ~name:updated_meta.name
                ~turn_generation:lifecycle.turn_generation
                ~compaction:lifecycle.compaction
                ~handoff_json:lifecycle.handoff_json;
              (match explicit_accountability_claim with
              | Some claim ->
                  let trace_id =
                    Keeper_id.Trace_id.to_string updated_meta.runtime.trace_id
                  in
                  let strong_evidence =
                    result.tools_used
                    |> List.exists (fun tool_name ->
                           let trimmed = String.trim tool_name in
                           trimmed <> ""
                           && not (String.equal trimmed (Tool_name.Keeper.to_string Tool_name.Keeper.Stay_silent)))
                  in
                  let tool_refs =
                    result.tools_used
                    |> List.filter_map (fun tool_name ->
                           let trimmed = String.trim tool_name in
                           if trimmed = ""
                              || String.equal trimmed (Tool_name.Keeper.to_string Tool_name.Keeper.Stay_silent)
                           then None
                           else Some ("tool:" ^ trimmed))
                  in
                  let turn_refs =
                    [ Printf.sprintf "turn:%s:%d" trace_id
                        updated_meta.runtime.usage.total_turns ]
                  in
                  Keeper_accountability.record_completion_claim ctx.config
                    ~keeper_name:updated_meta.name
                    ~agent_name:updated_meta.agent_name
                    ~trace_id
                    ~turn_number:updated_meta.runtime.usage.total_turns
                    ~subject:claim.subject
                    ?task_id:claim.task_id
                    ~evidence_refs:claim.evidence_refs
                    ~surface:"keeper_msg"
                    ~strong_evidence
                    ~strong_evidence_refs:(tool_refs @ turn_refs)
                    ()
              | None -> ());
              start_keepalive ctx updated_meta;
              Progress.Tracker.complete turn_tracker
                ~message:(Printf.sprintf "Turn completed: %d tool calls" result.tool_calls_made) ();
              let reply_json =
                let surface_model_used = Keeper_agent_run.surface_model_used result in
                let u = result.usage in
                let cost_field = match u.cost_usd with
                  | Some c -> `Float c
                  | None -> `Null
                in
                `Assoc [
                  ("reply", `String result.response_text);
                  ("model", `String surface_model_used);
                  ("model_used_raw", `String result.model_used);
                  ("turns", `Int result.turn_count);
                  ("tool_calls", `Int result.tool_calls_made);
                  ("usage", `Assoc [
                    ("input_tokens", `Int u.input_tokens);
                    ("output_tokens", `Int u.output_tokens);
                    ("cache_creation_input_tokens", `Int u.cache_creation_input_tokens);
                    ("cache_read_input_tokens", `Int u.cache_read_input_tokens);
                    ("cost_usd", cost_field);
                  ]);
                ]
              in
              (true, Yojson.Safe.to_string reply_json)

))))
