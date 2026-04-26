(** Keeper meta JSON codec facade.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while scrubbing, parsing, and serialization stay in
    smaller private modules. *)

open Keeper_types_profile
open Keeper_meta_contract
include Keeper_meta_json_scrub

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  let rt = m.runtime in
  (* Layer 2 PR-B (commit 5): personality fields go through
     [Keeper_personality_io.to_json].  Inlining four [`String] pairs
     created the original asymmetry that drove the drift loop
     (#10479 PR-A); centralising the write side guarantees symmetry
     with [Keeper_personality_io.parse].
     "models" is intentionally omitted from serialization (see
     removed_keeper_meta_key_names + scrub_persisted_keeper_meta_json
     — re-emitting causes a scrub → write → re-scrub loop). *)
  let personality_pairs =
    Keeper_personality_io.to_json
      {
        will = m.will;
        needs = m.needs;
        desires = m.desires;
        instructions = m.instructions;
      }
  in
  `Assoc
    ([ "name", `String m.name
     ; "agent_name", `String m.agent_name
     ; "trace_id", `String (Keeper_id.Trace_id.to_string rt.trace_id)
     ; "trace_history", `List (List.map (fun s -> `String s) rt.trace_history)
     ; "goal", `String m.goal
     ; "short_goal", `String m.short_goal
     ; "mid_goal", `String m.mid_goal
     ; "long_goal", `String m.long_goal
     ; "social_model", `String m.social_model
     ; "cascade_name", `String m.cascade_name
     ]
     @ personality_pairs
     @ [
      "policy_voice_enabled", `Bool m.policy_voice_enabled
    ; "sandbox_profile", `String (sandbox_profile_to_string m.sandbox_profile)
    ; "network_mode", `String (network_mode_to_string m.network_mode)
    ; "shared_memory_scope", `String (shared_memory_scope_to_string m.shared_memory_scope)
    ; "allowed_paths", `List (List.map (fun s -> `String s) m.allowed_paths)
    ; "tool_access", tool_access_to_json m.tool_access
    ; "tool_preset_source", Json_util.string_opt_to_json m.tool_preset_source
    ; "tool_denylist", `List (List.map (fun s -> `String s) m.tool_denylist)
    ; "mention_targets", `List (List.map (fun s -> `String s) m.mention_targets)
    ; "room_signal_prompt_enabled", `Bool m.room_signal_prompt_enabled
    ; "joined_room_ids", `List (List.map (fun s -> `String s) m.joined_room_ids)
    ; "last_seen_seq_by_room", room_seq_map_to_json m.last_seen_seq_by_room
    ; "generation", `Int rt.generation
    ; "proactive_enabled", `Bool m.proactive.enabled
    ; "proactive_idle_sec", `Int m.proactive.idle_sec
    ; "proactive_cooldown_sec", `Int m.proactive.cooldown_sec
    ; "compaction_profile", `String m.compaction.profile
    ; "compaction_ratio_gate", `Float m.compaction.ratio_gate
    ; "compaction_message_gate", `Int m.compaction.message_gate
    ; "compaction_token_gate", `Int m.compaction.token_gate
    ; "continuity_compaction_cooldown_sec", `Int m.compaction.cooldown_sec
    ; "max_checkpoint_messages", `Int m.compaction.max_checkpoint_messages
    ; "auto_handoff", `Bool m.auto_handoff
    ; "handoff_threshold", `Float m.handoff_threshold
    ; "handoff_cooldown_sec", `Int m.handoff_cooldown_sec
    ; "voice_enabled", `Bool m.voice_enabled
    ; "voice_channel", `String m.voice_channel
    ; "voice_agent_id", `String m.voice_agent_id
    ; "last_handoff_ts", `Float rt.last_handoff_ts
    ; "created_at", `String m.created_at
    ; "updated_at", `String m.updated_at
    ; "total_turns", `Int rt.usage.total_turns
    ; "total_input_tokens", `Int rt.usage.total_input_tokens
    ; "total_output_tokens", `Int rt.usage.total_output_tokens
    ; "total_tokens", `Int rt.usage.total_tokens
    ; "total_cost_usd", `Float rt.usage.total_cost_usd
    ; "last_turn_ts", `Float rt.usage.last_turn_ts
    ; "last_model_used", `String rt.usage.last_model_used
    ; "last_input_tokens", `Int rt.usage.last_input_tokens
    ; "last_output_tokens", `Int rt.usage.last_output_tokens
    ; "last_total_tokens", `Int rt.usage.last_total_tokens
    ; "last_latency_ms", `Int rt.usage.last_latency_ms
    ; "compaction_count", `Int rt.compaction_rt.count
    ; "last_compaction_ts", `Float rt.compaction_rt.last_ts
    ; "last_compaction_before_tokens", `Int rt.compaction_rt.last_before_tokens
    ; "last_compaction_after_tokens", `Int rt.compaction_rt.last_after_tokens
    ; "proactive_count_total", `Int rt.proactive_rt.count_total
    ; "last_proactive_ts", `Float rt.proactive_rt.last_ts
    ; "proactive_visible_count_total", `Int rt.proactive_rt.visible_count_total
    ; "last_visible_proactive_ts", `Float rt.proactive_rt.last_visible_ts
    ; ( "last_proactive_outcome"
      , `String (proactive_cycle_outcome_to_string rt.proactive_rt.last_outcome) )
    ; "last_proactive_reason", `String rt.proactive_rt.last_reason
    ; "last_proactive_preview", `String rt.proactive_rt.last_preview
    ; "last_work_discovery_ts", `Float rt.proactive_rt.last_work_discovery_ts
    ; "work_discovery_count", `Int rt.proactive_rt.work_discovery_count
    ; "consecutive_noop_count", `Int rt.proactive_rt.consecutive_noop_count
    ; "last_compaction_check_ts", `Float rt.compaction_rt.last_check_ts
    ; "last_compaction_decision", `String rt.compaction_rt.last_decision
    ; "last_continuity_update_ts", `Float rt.last_continuity_update_ts
    ; "continuity_summary", `String m.continuity_summary
    ; "active_goal_ids", `List (List.map (fun s -> `String s) m.active_goal_ids)
    ; "last_autonomous_action_at", `String rt.last_autonomous_action_at
    ; "autonomous_action_count", `Int rt.autonomous_action_count
    ; "autonomous_turn_count", `Int rt.autonomous_turn_count
    ; "autonomous_text_turn_count", `Int rt.autonomous_text_turn_count
    ; "autonomous_tool_turn_count", `Int rt.autonomous_tool_turn_count
    ; "board_reactive_turn_count", `Int rt.board_reactive_turn_count
    ; "mention_reactive_turn_count", `Int rt.mention_reactive_turn_count
    ; "noop_turn_count", `Int rt.noop_turn_count
    ; "consecutive_noop_count", `Int rt.consecutive_noop_count
    ; "last_speech_act", `String rt.last_speech_act
    ; "last_social_transition_reason", `String rt.last_social_transition_reason
    ; "last_active_desire", `String rt.last_active_desire
    ; "last_current_intention", `String rt.last_current_intention
    ; "last_blocker", `String rt.last_blocker
    ; ( "last_blocker_class"
      , match rt.last_blocker_class with
        | Some bc -> `String (blocker_class_to_string bc)
        | None -> `Null )
    ; "last_need", `String rt.last_need
    ; "paused", `Bool m.paused
    ; "autoboot_enabled", `Bool m.autoboot_enabled
    ; ( "current_task_id"
      , Json_util.string_opt_to_json
          (Option.map Keeper_id.Task_id.to_string m.current_task_id) )
    ; "max_context_override", Json_util.int_opt_to_json m.max_context_override
    ; "work_discovery_enabled", Json_util.bool_opt_to_json m.work_discovery_enabled
    ; ( "work_discovery_sources"
      , match m.work_discovery_sources with
        | Some xs -> `List (List.map (fun s -> `String s) xs)
        | None -> `Null )
    ; ( "work_discovery_interval_sec"
      , Json_util.int_opt_to_json m.work_discovery_interval_sec )
    ; "work_discovery_guidance", Json_util.string_opt_to_json m.work_discovery_guidance
    ; ( "telemetry_feedback_enabled"
      , Json_util.bool_opt_to_json m.telemetry_feedback_enabled )
    ; ( "telemetry_feedback_window_hours"
      , Json_util.int_opt_to_json m.telemetry_feedback_window_hours )
    ; "per_provider_timeout_s", Json_util.float_opt_to_json m.per_provider_timeout_s
    ; "always_approve", Json_util.bool_opt_to_json m.always_approve
    ; ( "keeper_id"
      , match m.keeper_id with
        | Some uid -> Keeper_id.uid_to_yojson uid
        | None -> `Null )
    ; "oas_env", `Assoc (List.map (fun (k, v) -> k, `String v) m.oas_env)
    ; "meta_version", `Int m.meta_version
    ])
;;

include Keeper_meta_json_parse

let fallback_canonical_keeper_meta_key_names =
  [ "name"
  ; "agent_name"
  ; "trace_id"
  ; "trace_history"
  ; "goal"
  ; "short_goal"
  ; "mid_goal"
  ; "long_goal"
  ; "social_model"
  ; "cascade_name"
  ; "models"
  ; "will"
  ; "needs"
  ; "desires"
  ; "instructions"
  ; "policy_voice_enabled"
  ; "allowed_paths"
  ; "tool_access"
  ; "tool_denylist"
  ; "mention_targets"
  ; "room_signal_prompt_enabled"
  ; "joined_room_ids"
  ; "last_seen_seq_by_room"
  ; "generation"
  ; "proactive_enabled"
  ; "proactive_idle_sec"
  ; "proactive_cooldown_sec"
  ; "compaction_profile"
  ; "compaction_ratio_gate"
  ; "compaction_message_gate"
  ; "compaction_token_gate"
  ; "continuity_compaction_cooldown_sec"
  ; "auto_handoff"
  ; "handoff_threshold"
  ; "handoff_cooldown_sec"
  ; "voice_enabled"
  ; "voice_channel"
  ; "voice_agent_id"
  ; "last_handoff_ts"
  ; "created_at"
  ; "updated_at"
  ; "total_turns"
  ; "total_input_tokens"
  ; "total_output_tokens"
  ; "total_tokens"
  ; "total_cost_usd"
  ; "last_turn_ts"
  ; "last_model_used"
  ; "last_input_tokens"
  ; "last_output_tokens"
  ; "last_total_tokens"
  ; "last_latency_ms"
  ; "compaction_count"
  ; "last_compaction_ts"
  ; "last_compaction_before_tokens"
  ; "last_compaction_after_tokens"
  ; "proactive_count_total"
  ; "last_proactive_ts"
  ; "proactive_visible_count_total"
  ; "last_visible_proactive_ts"
  ; "last_proactive_outcome"
  ; "last_proactive_reason"
  ; "last_proactive_preview"
  ; "last_work_discovery_ts"
  ; "work_discovery_count"
  ; "last_compaction_check_ts"
  ; "last_compaction_decision"
  ; "last_continuity_update_ts"
  ; "continuity_summary"
  ; "active_goal_ids"
  ; "last_autonomous_action_at"
  ; "autonomous_action_count"
  ; "autonomous_turn_count"
  ; "autonomous_text_turn_count"
  ; "autonomous_tool_turn_count"
  ; "board_reactive_turn_count"
  ; "mention_reactive_turn_count"
  ; "noop_turn_count"
  ; "consecutive_noop_count"
  ; "last_speech_act"
  ; "last_social_transition_reason"
  ; "last_active_desire"
  ; "last_current_intention"
  ; "last_blocker"
  ; "last_blocker_class"
  ; "last_need"
  ; "paused"
  ; "autoboot_enabled"
  ; "current_task_id"
  ; "max_context_override"
  ; "work_discovery_enabled"
  ; "work_discovery_sources"
  ; "work_discovery_interval_sec"
  ; "work_discovery_guidance"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "per_provider_timeout_s"
  ; "oas_env"
  ]
;;

let canonical_keeper_meta_key_names =
  let seed_json =
    `Assoc
      [ "name", `String "__keeper-meta-key-seed__"
      ; "agent_name", `String "__keeper-meta-key-seed__"
      ; "trace_id", `String "__keeper-meta-key-seed__"
      ]
  in
  match meta_of_json seed_json with
  | Ok meta ->
    (match meta_to_json meta with
     | `Assoc fields -> fields |> List.map fst |> dedupe_keep_order
     | _ -> fallback_canonical_keeper_meta_key_names)
  | Error msg ->
    Log.Keeper.warn
      "canonical_keeper_meta_key_names seed failed: %s; falling back to static keys"
      msg;
    fallback_canonical_keeper_meta_key_names
;;

let warn_unknown_keeper_meta_keys ~path (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let unknown =
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key canonical_keeper_meta_key_names then None else Some key)
      |> dedupe_keep_order
    in
    if unknown <> []
    then
      Log.Keeper.warn
        "keeper meta %s has unknown keys: %s"
        path
        (String.concat ", " unknown)
  | _ -> ()
;;
