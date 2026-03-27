open Operator_pending_confirm
open Result_syntax

include Operator_digest_types
include Operator_digest_session
open Operator_digest_guidance

let slow_digest_phase_threshold_ms = 1000.0
let slow_digest_total_threshold_ms = 5000.0

let log_digest_phase_if_slow ~actor ~target_type ~phase started_at =
  let finished_at = Time_compat.now () in
  let phase_ms = (finished_at -. started_at) *. 1000.0 in
  if phase_ms >= slow_digest_phase_threshold_ms then
    Log.Dashboard.info
      "[operator_digest] slow phase actor=%s target=%s phase=%s %.0fms"
      actor target_type phase phase_ms;
  finished_at

let assoc_member key json =
  match json with
  | `Assoc _ -> U.member key json
  | _ -> `Assoc []

let build_room_attention_items ?command_plane_summary config =
  let command_plane_summary =
    match command_plane_summary with
    | Some s -> s
    | None -> Command_plane_v2.summary_json config
  in
  let microarch_signals =
    command_plane_summary
    |> assoc_member "operations"
    |> assoc_member "microarch"
    |> assoc_member "signals"
  in
  let intent_summary =
    command_plane_summary
    |> assoc_member "intents"
    |> assoc_member "summary"
  in
  let signal_items =
    [
      ( "command_issue_pressure",
        "command-plane issue pressure is elevated",
        microarch_signals |> U.member "issue_pressure" );
      ( "command_cache_contention",
        "command-plane cache contention is elevated",
        microarch_signals |> U.member "cache_contention" );
      ( "command_scheduler_efficiency",
        "command-plane scheduler efficiency is degraded",
        microarch_signals |> U.member "scheduler_efficiency" );
      ( "command_routing_confidence",
        "command-plane routing confidence is degraded",
        microarch_signals |> U.member "routing_confidence" );
      ( "command_quality_per_token",
        "command-plane quality-per-token is degraded",
        microarch_signals |> U.member "quality_per_token" );
      ( "command_verification_gate_failures",
        "command-plane verification gate failures are accumulating",
        microarch_signals |> U.member "verification_gate_failures" );
      ( "command_rework_rate",
        "command-plane rework rate is elevated",
        microarch_signals |> U.member "rework_rate" );
      ( "command_artifact_scope_drift",
        "command-plane artifact scope drift is elevated",
        microarch_signals |> U.member "artifact_scope_drift" );
      ( "command_speculative_posture",
        "command-plane speculative posture needs review",
        microarch_signals |> U.member "speculative_posture" );
    ]
    |> List.filter_map (fun (kind, summary, signal_json) ->
           match signal_json |> U.member "tone" with
           | `String "warn" ->
               Some
                 {
                   kind;
                   severity = "warn";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence = signal_json;
                 }
           | `String "bad" ->
               Some
                 {
                   kind;
                   severity = "bad";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence = signal_json;
                 }
           | _ -> None)
  in
  let intent_items =
    [
      ( "intent_blocked",
        "blocked intents need intervention",
        intent_summary |> U.member "blocked",
        "blocked" );
      ( "intent_handoff_ready",
        "handoff-ready intents need continuity review",
        intent_summary |> U.member "handoff_ready",
        "handoff_ready" );
    ]
    |> List.filter_map (fun (kind, summary, value_json, field_name) ->
           match value_json with
           | `Int count when count > 0 ->
               Some
                 {
                   kind;
                   severity = if count >= 3 then "bad" else "warn";
                   summary;
                   target_type = "room";
                   target_id = None;
                   actor = None;
                   evidence =
                     `Assoc
                       [
                         (field_name, `Int count);
                       ];
                 }
           | _ -> None)
  in
  let pending_confirms = read_pending_confirms config in
  let pending_items =
    if pending_confirms = [] then []
    else
      [
        {
          kind = "pending_confirm_waiting";
          severity = "warn";
          summary =
            Printf.sprintf "%d pending confirmation(s) are waiting for operator input"
              (List.length pending_confirms);
          target_type = "room";
          target_id = None;
          actor = None;
          evidence = `Assoc [ ("count", `Int (List.length pending_confirms)) ];
        };
      ]
  in
  List.sort compare_attention (pending_items @ signal_items @ intent_items)

let room_recommendations ?command_plane_summary config =
  let command_plane_summary =
    match command_plane_summary with
    | Some s -> s
    | None -> Command_plane_v2.summary_json config
  in
  let microarch_signals =
    command_plane_summary
    |> assoc_member "operations"
    |> assoc_member "microarch"
    |> assoc_member "signals"
  in
  let intent_summary =
    command_plane_summary
    |> assoc_member "intents"
    |> assoc_member "summary"
  in
  let signal_recommendations =
    [
      ( microarch_signals |> U.member "issue_pressure",
        "broadcast",
        "command-plane issue pressure is elevated",
        "[operator] Issue pressure is elevated. Inspect blocked operations, run a dispatch tick, and checkpoint or finalize stale work." );
      ( microarch_signals |> U.member "routing_confidence",
        "broadcast",
        "command-plane routing confidence is degraded",
        "[operator] Routing confidence is low. Inspect candidate scoring and avoid risky manual rebalance until blockers clear." );
      ( microarch_signals |> U.member "quality_per_token",
        "broadcast",
        "command-plane quality-per-token is degraded",
        "[operator] Quality per token is low. Narrow the task graph, reduce weak candidates, and keep coding stages explicit before spawning more workers." );
      ( microarch_signals |> U.member "verification_gate_failures",
        "broadcast",
        "command-plane verification gate failures are accumulating",
        "[operator] Verification failures are stacking up. Stop widening the swarm, inspect implement->verify handoff quality, and patch failing gates first." );
      ( microarch_signals |> U.member "rework_rate",
        "broadcast",
        "command-plane rework rate is elevated",
        "[operator] Rework is high. Deduplicate artifact ownership and collapse parallel work that is touching the same scope." );
      ( microarch_signals |> U.member "artifact_scope_drift",
        "broadcast",
        "command-plane artifact scope drift is elevated",
        "[operator] Artifact scope drift is rising. Require explicit artifact_scope on coding stages before further routing or review." );
      ( microarch_signals |> U.member "cache_contention",
        "broadcast",
        "command-plane cache contention is elevated",
        "[operator] Cache contention is elevated. Reduce concurrent hot lanes or rebalance worker placement before scaling further." );
      ( microarch_signals |> U.member "speculative_posture",
        "broadcast",
        "command-plane speculative posture needs review",
        "[operator] Speculative posture is unstable. Review commit and abort rates before widening speculation." );
      ( intent_summary |> U.member "blocked",
        "broadcast",
        "blocked intents need intervention",
        "[operator] Some intents are blocked. Inspect intent forecast, missing dependencies, and current focus before issuing more work." );
      ( intent_summary |> U.member "handoff_ready",
        "broadcast",
        "handoff-ready intents need continuity review",
        "[operator] Handoff-ready intents are accumulating. Review continuity and either finalize or hand off explicitly." );
    ]
    |> List.filter_map
         (fun (signal_json, action_type, reason, message) ->
           match signal_json with
           | `Assoc _ -> (
               match signal_json |> U.member "tone" with
               | `String ("warn" | "bad" as severity) ->
                   Some
                     {
                       action_type;
                       target_type = "room";
                       target_id = None;
                       severity;
                       reason;
                       suggested_payload = `Assoc [ ("message", `String message) ];
                     }
               | _ -> None)
           | `Int count when count > 0 ->
               Some
                 {
                   action_type;
                   target_type = "room";
                   target_id = None;
                   severity = if count >= 3 then "bad" else "warn";
                   reason;
                   suggested_payload = `Assoc [ ("message", `String message) ];
                 }
           | _ -> None)
  in
  dedup_recommendations signal_recommendations

let digest_json ?actor ?target_type ?target_id ?include_workers ?sessions
    ?command_plane_summary ?swarm_status (ctx : 'a context) :
    (Yojson.Safe.t, string) result =
  let config = ctx.config in
  if not (Room.is_initialized config) then
    Ok
      (`Assoc
        [
          ("trace_id", `String (trace_id "opsd"));
          ("target_type", `String "room");
          ("target_id", `Null);
          ("health", `String "ok");
          ("judgment_owner", `String "fallback_read_model");
          ("authoritative_judgment_available", `Bool false);
          ("provenance_summary", operator_surface_contract_json);
          ("judgment", `Null);
          ("resident_judge_runtime", resident_judge_runtime_json config);
          ("command_plane", `Assoc []);
          ("swarm_status", Swarm_status.empty_json);
          ("attention_items", `List []);
          ("attention_summary", summary_of_attention_items []);
          ("pending_confirm_summary", pending_confirm_summary_json_of_scope (pending_confirm_scope_of_entries ?actor []));
          ("recommended_actions", `List []);
          ("recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_guidance_layer", `String "fallback");
          ("active_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("active_recommended_actions", `List []);
          ("active_recommendation_source", `String "fallback");
          ("active_recommendation_summary", summary_of_recommendations ~actor:"dashboard" []);
          ("fallback_recommended_actions", `List []);
          ("session_cards", `List []);
          ("worker_cards", `List []);
        ])
  else
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let* target_type = normalize_digest_target_type target_type in
    let t_start = Time_compat.now () in
    let now = Time_compat.now () in
    let tracked_sessions =
      match sessions with
      | Some s -> s
      | None -> Team_session_store.list_sessions config
    in
    let t_sessions =
      log_digest_phase_if_slow ~actor:actor_name ~target_type
        ~phase:"session_list" t_start
    in
    let command_plane_digest_json =
      match command_plane_summary with
      | Some summary -> summary
      | None -> Command_plane_v2.summary_json ~sessions:tracked_sessions config
    in
    let t_command =
      log_digest_phase_if_slow ~actor:actor_name ~target_type
        ~phase:"command_plane_summary" t_sessions
    in
    let swarm_status_json =
      match swarm_status with
      | Some json -> json
      | None ->
          Swarm_status.build_json ~timeline_limit_override:6 config
    in
    let t_swarm =
      log_digest_phase_if_slow ~actor:actor_name ~target_type
        ~phase:"swarm_status" t_command
    in
    match target_type with
    | "room" ->
        let sessions =
          tracked_sessions
          |> List.map (fun session -> build_session_digest config session ~now)
          |> List.sort compare_session_digest
        in
        let limited_sessions =
          sessions |> List.to_seq |> Seq.take room_digest_session_limit |> List.of_seq
        in
        let t_session_digest =
          log_digest_phase_if_slow ~actor:actor_name ~target_type
            ~phase:"session_digest" t_swarm
        in
        let attention_items =
          build_room_attention_items ~command_plane_summary:command_plane_digest_json config
          @ (limited_sessions |> List.concat_map (fun digest -> digest.attention_items))
          |> List.sort compare_attention
        in
        let t_attention =
          log_digest_phase_if_slow ~actor:actor_name ~target_type
            ~phase:"attention_items" t_session_digest
        in
        let recommended_actions =
          dedup_recommendations
            (room_recommendations ~command_plane_summary:command_plane_digest_json config
            @ (limited_sessions
              |> List.concat_map (fun digest -> digest.recommended_actions)))
        in
        let t_recommendations =
          log_digest_phase_if_slow ~actor:actor_name ~target_type
            ~phase:"recommended_actions" t_attention
        in
        let fallback_recommendation_summary =
          summary_of_recommendations ~actor:actor_name recommended_actions
        in
        let t_recommendation_summary =
          log_digest_phase_if_slow ~actor:actor_name ~target_type
            ~phase:"recommendation_summary" t_recommendations
        in
        let pending_confirm_summary = pending_confirm_summary_json ?actor config in
        let t_pending_confirm =
          log_digest_phase_if_slow ~actor:actor_name ~target_type
            ~phase:"pending_confirm_summary" t_recommendation_summary
        in
        let active_guidance =
          active_guidance_fields ~config ~actor:actor_name ~target_type:"room"
            ~target_id:None ~fallback_recommendations:recommended_actions
            ~fallback_summary:fallback_recommendation_summary
        in
        let t_active_guidance =
          log_digest_phase_if_slow ~actor:actor_name ~target_type
            ~phase:"active_guidance" t_pending_confirm
        in
        let session_cards_json =
          `List
            (List.map (session_card_to_yojson ~actor:actor_name) limited_sessions)
        in
        let t_session_cards =
          log_digest_phase_if_slow ~actor:actor_name ~target_type
            ~phase:"session_cards" t_active_guidance
        in
        let resident_judge_runtime = resident_judge_runtime_json config in
        let t_resident_runtime =
          log_digest_phase_if_slow ~actor:actor_name ~target_type
            ~phase:"resident_judge_runtime" t_session_cards
        in
        let total_ms = (t_resident_runtime -. t_start) *. 1000.0 in
        if total_ms >= slow_digest_total_threshold_ms then
          Log.Dashboard.warn
            "[operator_digest] slow digest actor=%s target=%s total=%.0fms tracked_sessions=%d visible_session_cards=%d"
            actor_name target_type total_ms (List.length tracked_sessions)
            (List.length limited_sessions);
        Ok
          (`Assoc
            ([
              ("trace_id", `String (trace_id "opsd"));
              ("target_type", `String "room");
              ("target_id", `Null);
              ("health", `String (health_from_attention_items attention_items));
              ("provenance_summary", operator_surface_contract_json);
              ("resident_judge_runtime", resident_judge_runtime);
              ("command_plane", command_plane_digest_json);
              ("swarm_status", swarm_status_json);
              ("role_census", aggregate_worker_class_counts tracked_sessions);
              ("runtime_pools", aggregate_runtime_pool_counts tracked_sessions);
              ("lane_census", aggregate_lane_counts tracked_sessions);
              ("controller_census", aggregate_controller_counts tracked_sessions);
              ("control_domains", aggregate_control_domain_counts tracked_sessions);
              ("model_tiers", aggregate_tier_counts tracked_sessions);
              ("task_profiles", aggregate_task_profile_counts tracked_sessions);
              ("escalation_count", `Int (aggregate_escalation_count tracked_sessions));
              ("local_runtime", aggregated_local_runtime_json tracked_sessions);
              ("attention_items", `List (List.map attention_item_to_yojson attention_items));
              ("attention_summary", summary_of_attention_items attention_items);
              ("pending_confirm_summary", pending_confirm_summary);
              ( "recommended_actions",
                `List
                  (List.map (recommended_action_to_yojson ~actor:actor_name)
                     recommended_actions) );
              ("recommendation_summary", fallback_recommendation_summary);
              ("session_cards", session_cards_json);
              ("worker_cards", `List []);
            ]
            @ active_guidance))
    | "team_session" -> (
        match target_id with
        | None -> Error "target_id is required when target_type=team_session"
        | Some session_id -> (
            match Team_session_store.load_session config session_id with
            | None ->
                Error (Printf.sprintf "team session not found: %s" session_id)
            | Some session ->
                let digest = build_session_digest config session ~now in
                let worker_cards =
                  let should_include =
                    match include_workers with
                    | Some value -> value
                    | None -> true
                  in
                  if should_include then digest.worker_cards else []
                in
                let fallback_recommendation_summary =
                  summary_of_recommendations ~actor:actor_name
                    digest.recommended_actions
                in
                let active_guidance =
                  active_guidance_fields ~config ~actor:actor_name
                    ~target_type:"team_session" ~target_id:(Some session_id)
                    ~fallback_recommendations:digest.recommended_actions
                    ~fallback_summary:fallback_recommendation_summary
                in
                Ok
                  (`Assoc
                    ([
                      ("trace_id", `String (trace_id "opsd"));
                      ("target_type", `String "team_session");
                      ("target_id", `String session_id);
                      ("health", `String digest.health);
                      ("provenance_summary", operator_surface_contract_json);
                      ("resident_judge_runtime", resident_judge_runtime_json config);
                      ("command_plane", command_plane_digest_json);
                      ("swarm_status", swarm_status_json);
                      ( "attention_items",
                        `List
                          (List.map attention_item_to_yojson digest.attention_items)
                      );
                      ("attention_summary", summary_of_attention_items digest.attention_items);
                      ( "recommended_actions",
                        `List
                          (List.map (recommended_action_to_yojson ~actor:actor_name)
                             digest.recommended_actions) );
                      ("recommendation_summary", fallback_recommendation_summary);
                      ("session_cards", `List [ session_card_to_yojson ~actor:actor_name digest ]);
                      ("worker_cards", `List (List.map worker_card_to_yojson worker_cards));
                    ]
                    @ active_guidance))))
    | _ -> Error "unsupported target_type"
