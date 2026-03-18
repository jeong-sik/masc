(** Keeper_keepalive — keepalive registry and resident heartbeat fiber. *)

open Keeper_types
open Keeper_memory
open Keeper_execution

type keepalive_entry = {
  stop : bool ref;
  started_at : float;
}

(** Per-keeper last known agent count for detecting changes. *)
let last_agent_counts : (string, int) Hashtbl.t = Hashtbl.create 8

(* OAS Event_bus ref — set via bootstrap *)
let bus_ref : Agent_sdk.Event_bus.t option ref = ref None
let set_bus bus = bus_ref := Some bus

let keepalives : (string, keepalive_entry) Hashtbl.t = Hashtbl.create 8

let running_keepers () = Hashtbl.length keepalives

let keeper_keepalive_running name = Hashtbl.mem keepalives name

let keeper_keepalive_started_at name =
  Hashtbl.find_opt keepalives name |> Option.map (fun entry -> entry.started_at)

let keeper_spawn_slots_available () =
  let max_keepers = Env_config.KeeperBootstrap.max_active_keepers in
  max_keepers <= 0 || running_keepers () < max_keepers

let start_keepalive ?(proactive_warmup_sec = 0) (ctx : _ context)
    (m : keeper_meta) : unit =
  if not m.presence_keepalive then ()
  else if Hashtbl.mem keepalives m.name then ()
  else if not (keeper_spawn_slots_available ()) then ()
  else (
    let stop = ref false in
    Hashtbl.replace keepalives m.name
      { stop; started_at = Time_compat.now () };
    (try
       if not (Room_utils.is_initialized ctx.config) then
         ignore (Room.init ctx.config ~agent_name:None)
     with exn ->
       Log.Keeper.error "room init failed: %s"
         (Printexc.to_string exn));
    (try
       let synced = ensure_keeper_room_presence ctx.config m in
       ignore (write_meta ctx.config synced)
     with exn ->
       Log.Keeper.error "room presence bootstrap failed: %s"
         (Printexc.to_string exn));
    Eio.Fiber.fork ~sw:ctx.sw (fun () ->
        let keepalive_started_ts = Time_compat.now () in
        let snapshot_interval_sec =
          match Sys.getenv_opt "MASC_KEEPER_SNAPSHOT_SEC" with
          | Some s ->
              (try
                 max 15 (min 3600 (int_of_string (String.trim s)))
               with Failure _ -> 60)
          | None -> 60
        in
        let last_snapshot_ts = ref 0.0 in
        let rec loop () =
          if !stop then ()
          else (
            let meta_current =
              match read_meta ctx.config m.name with
              | Ok (Some latest) -> latest
              | _ -> m
            in
            (try
               let synced = ensure_keeper_room_presence ctx.config meta_current in
               ignore (write_meta ctx.config synced)
             with exn ->
               Log.Keeper.error "room heartbeat failed: %s"
                 (Printexc.to_string exn));
            let meta_current =
              match read_meta ctx.config m.name with
              | Ok (Some latest) -> latest
              | _ -> meta_current
            in
            let now_ts = Time_compat.now () in
            if now_ts -. !last_snapshot_ts >= float_of_int snapshot_interval_sec
            then (
              (try
                 let metrics_path =
                   keeper_metrics_path ctx.config meta_current.name
                 in
                 let primary_model =
                   match model_specs_of_strings meta_current.models with
                   | Ok (primary :: _) -> primary
                   | _ -> Llm.default_local_model_spec ()
                 in
                 let base_dir = session_base_dir ctx.config in
                 let _session, ctx_opt =
                   load_context_from_checkpoint
                     ~trace_id:meta_current.trace_id
                     ~primary_model_max_tokens:primary_model.max_context
                     ~base_dir
                 in
                 (match ctx_opt with
                 | None -> ()
                 | Some c ->
                     let latest_user_message =
                       latest_message_content_by_role ~role:Llm.User
                         c.messages
                     in
                     let latest_assistant_message =
                       latest_message_content_by_role
                         ~role:Llm.Assistant c.messages
                     in
                     let continuity_snapshot =
                       latest_state_snapshot_from_messages c.messages
                     in
                     let continuity_summary =
                       match continuity_snapshot with
                       | Some s -> keeper_state_snapshot_to_summary_text s
                       | None ->
                           let trimmed =
                             String.trim meta_current.continuity_summary
                           in
                           if trimmed = "" then
                             "No continuity snapshot available."
                           else trimmed
                     in
                     let repetition_risk =
                       repetition_risk_score ~messages:c.messages
                         ~candidate_reply:None
                     in
                     let goal_alignment =
                       goal_alignment_score ~meta:meta_current
                         ~user_message:latest_user_message
                         ~assistant_reply:latest_assistant_message
                     in
                     let response_alignment =
                       match latest_user_message, latest_assistant_message with
                       | Some user_message, Some assistant_message ->
                           jaccard_similarity user_message assistant_message
                       | _ -> 0.0
                     in
                     let auto_rules =
                       evaluate_keeper_auto_rules ~meta:meta_current
                         ~context_ratio:(Context_manager.context_ratio c)
                         ~message_count:(List.length c.messages)
                         ~token_count:c.token_count ~repetition_risk
                         ~goal_alignment ~response_alignment
                     in
                     let snapshot =
                       `Assoc
                         [
                           ("ts", `String (now_iso ()));
                           ("ts_unix", `Float now_ts);
                           ("channel", `String "heartbeat");
                           ("name", `String meta_current.name);
                           ("agent_name", `String meta_current.agent_name);
                           ("trace_id", `String meta_current.trace_id);
                           ("generation", `Int meta_current.generation);
                           ("model_used", `String meta_current.last_model_used);
                           ( "usage",
                             `Assoc
                               [
                                 ("input_tokens", `Int 0);
                                 ("output_tokens", `Int 0);
                                 ("total_tokens", `Int 0);
                               ] );
                           ("latency_ms", `Int 0);
                           ("cost_usd", `Float 0.0);
                           ( "context_ratio",
                             `Float (Context_manager.context_ratio c) );
                           ("context_tokens", `Int c.token_count);
                           ("context_max", `Int c.max_tokens);
                           ("message_count", `Int (List.length c.messages));
                           ( "continuity_state",
                             match continuity_snapshot with
                             | None -> `Null
                             | Some s -> keeper_state_snapshot_to_json s );
                           ("continuity_summary", `String continuity_summary);
                           ("compacted", `Bool false);
                           ("compaction_before_tokens", `Int c.token_count);
                           ("compaction_after_tokens", `Int c.token_count);
                           ("work_kind", `String "status_tick");
                           ("tool_call_count", `Int 0);
                           ("tools_used", `List []);
                           ("snapshot_source", `String "keeper_context_status");
                           ("memory_check", memory_check_default_json ());
                           ( "auto_rules",
                             keeper_auto_rule_eval_to_json auto_rules );
                           ( "reflection",
                             keeper_reflection_payload_of_auto_rules auto_rules
                           );
                           ("auto_reflect", `Bool auto_rules.reflect);
                           ("auto_plan", `Bool auto_rules.plan);
                           ("auto_compact", `Bool auto_rules.compact);
                           ("auto_handoff", `Bool auto_rules.handoff);
                           ("repetition_risk", `Float repetition_risk);
                           ("goal_alignment", `Float goal_alignment);
                           ("response_alignment", `Float response_alignment);
                           ("goal_drift", `Float auto_rules.goal_drift);
                           ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                           ( "guardrail_stop_reason",
                             match auto_rules.guardrail_reason with
                             | Some reason -> `String reason
                             | None -> `Null );
                           ("handoff", `Assoc [ ("performed", `Bool false) ]);
                         ]
                     in
                     append_jsonl_line metrics_path snapshot;
                     (try
                        Sse.broadcast
                          (`Assoc
                            [
                              ("type", `String "keeper_heartbeat");
                              ("name", `String meta_current.name);
                              ("generation", `Int meta_current.generation);
                              ( "context_ratio",
                                `Float (Context_manager.context_ratio c) );
                              ("ts_unix", `Float now_ts);
                            ])
                      with exn ->
                        Log.Keeper.error "heartbeat SSE broadcast failed: %s"
                          (Printexc.to_string exn));
                     (* OAS: publish keeper snapshot event *)
                     (match !bus_ref with
                      | Some bus ->
                          Oas_events.publish_keeper_snapshot bus
                            ~keeper_name:meta_current.name
                            ~generation:meta_current.generation
                            ~context_ratio:(Context_manager.context_ratio c)
                            ~message_count:(List.length c.messages)
                      | None -> ()))
               with exn ->
                 Log.Keeper.error "heartbeat snapshot write failed: %s"
                   (Printexc.to_string exn));
              last_snapshot_ts := now_ts);
            (* Deliberation triage: run for llm_deliberation mode keepers *)
            let meta_after_triage =
              let pm =
                Keeper_contract.policy_mode_of_string meta_current.policy_mode
              in
              if Keeper_contract.policy_mode_is_deliberation pm then (
                let obs =
                  Keeper_deliberation.empty_world_observation
                    ~keeper_name:meta_current.name
                in
                (* L2 enrichment: read room state for richer world observation *)
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
                     Log.Keeper.warn "keepalive: task count query failed: %s" (Printexc.to_string exn);
                     (0, 0))
                in
                let current_agent_count =
                  (try
                     List.length (Room.get_agents_raw ctx.config)
                   with exn ->
                     Log.Keeper.warn "keepalive: agent count query failed: %s" (Printexc.to_string exn);
                     0)
                in
                let agent_count_changed =
                  let last_count =
                    match Hashtbl.find_opt last_agent_counts meta_current.name with
                    | Some c -> c
                    | None -> 0
                  in
                  let changed =
                    last_count > 0 && current_agent_count <> last_count
                  in
                  Hashtbl.replace last_agent_counts
                    meta_current.name current_agent_count;
                  changed
                in
                let obs =
                  { obs with
                    active_goal_count = List.length meta_current.active_goal_ids;
                    idle_seconds =
                      (let activity_ts =
                         max meta_current.last_turn_ts
                           meta_current.last_proactive_ts
                       in
                       if activity_ts <= 0.0 then 0
                       else int_of_float (max 0.0 (now_ts -. activity_ts)));
                    idle_gate = meta_current.proactive_idle_sec;
                    unclaimed_task_count = unclaimed_count;
                    failed_task_count = failed_count;
                    active_agent_count = current_agent_count;
                    agent_count_changed;
                  }
                in
                let triage_result = Keeper_deliberation.triage obs in
                let triggers_str =
                  match triage_result with
                  | Keeper_deliberation.Skip reason -> "skip:" ^ reason
                  | Keeper_deliberation.Triggered triggers ->
                      String.concat ","
                        (List.map
                           Keeper_deliberation.deliberation_trigger_to_string
                           triggers)
                in
                if Keeper_types.keeper_debug then
                  Log.KeeperExec.info "%s triage: %s"
                    meta_current.name triggers_str;
                { meta_current with last_triage_triggers = triggers_str })
              else meta_current
            in
            let proactive_warmup_elapsed =
              proactive_warmup_sec <= 0
              || now_ts -. keepalive_started_ts
                 >= float_of_int proactive_warmup_sec
            in
            let meta_after_proactive =
              if proactive_warmup_elapsed then
                (try
                   if
                     meta_after_triage.trigger_mode
                     |> Keeper_contract.trigger_mode_of_string
                     |> Keeper_contract.trigger_mode_is_explicit_only
                   then maybe_emit_explicit_room_replies ctx meta_after_triage
                   else maybe_emit_proactive ctx meta_after_triage
                 with exn ->
                   Log.Keeper.error "proactive emission failed: %s"
                     (Printexc.to_string exn);
                   meta_after_triage)
              else meta_after_triage
            in
            let base =
              float_of_int
                (max 30 (min 300 meta_after_proactive.presence_keepalive_sec))
            in
            let jitter = base *. 0.2 *. Random.float 1.0 in
            Eio.Time.sleep ctx.clock (base +. jitter);
            loop ())
        in
        loop ()))

let stop_keepalive name =
  match Hashtbl.find_opt keepalives name with
  | None -> ()
  | Some entry ->
      entry.stop := true;
      Hashtbl.remove keepalives name
