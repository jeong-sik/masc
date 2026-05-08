(** Keeper meta JSON parser.

    This module owns persisted JSON -> [keeper_meta] decoding.  Serialization
    stays in [Keeper_meta_json] so canonical-key derivation can use the public
    facade without creating a cycle. *)

open Keeper_types_profile
open Keeper_meta_contract
open Keeper_meta_json_scrub

type parsed_keeper_identity =
  { pk_name : string
  ; pk_agent_name : string
  ; pk_trace_id : Keeper_id.Trace_id.t
  ; pk_trace_history : string list
  ; pk_goal : string
  ; pk_short_goal : string
  ; pk_mid_goal : string
  ; pk_long_goal : string
  ; pk_social_model : string
  ; pk_cascade_name : string
  ; pk_cascade_ref : Cascade_ref.cascade_ref option
  ; pk_models : string list
  ; pk_will : string
  ; pk_needs : string
  ; pk_desires : string
  ; pk_instructions : string
  }

type parsed_keeper_policy =
  { pp_policy_voice_enabled : bool
  ; pp_sandbox_profile : sandbox_profile
  ; pp_sandbox_image : string option
  ; pp_network_mode : network_mode
  ; pp_allowed_paths : string list
  ; pp_tool_access : tool_access
  ; pp_tool_denylist : string list
  ; pp_mention_targets : string list
  ; pp_room_signal_prompt_enabled : bool
  ; pp_joined_room_ids : string list
  ; pp_last_seen_seq_by_room : (string * int) list
  ; pp_proactive : proactive_policy
  ; pp_compaction : compaction_policy
  ; pp_auto_handoff : bool
  ; pp_handoff_threshold : float
  ; pp_handoff_cooldown_sec : int
  ; pp_voice_enabled : bool
  ; pp_voice_channel : string
  ; pp_voice_agent_id : string
  ; pp_per_provider_timeout_s : float option
  ; pp_always_approve : bool option
  }

type parsed_keeper_state =
  { ps_created_at_raw : string
  ; ps_updated_at_raw : string
  ; ps_continuity_summary : string
  ; ps_active_goal_ids : string list
  ; ps_paused : bool
  ; ps_auto_resume_after_sec : float option
  ; ps_autoboot_enabled : bool
  ; ps_current_task_id : Keeper_id.Task_id.t option
  ; ps_max_context_override : int option
  ; ps_runtime : agent_runtime_state
  }

let parse_keeper_identity (json : Yojson.Safe.t) : (parsed_keeper_identity, string) result
  =
  let ident = Keeper_identity.parse_json_identity json in
  let pk_name = ident.keeper_name in
  let pk_agent_name = ident.agent_name in
  let pk_trace_id_raw = Option.value ~default:"" ident.trace_id in
  match
    if String.trim pk_trace_id_raw = ""
    then Error "missing trace_id in persisted keeper identity"
    else (
      match Keeper_id.Trace_id.of_string pk_trace_id_raw with
      | Ok x -> Ok x
      | Error err -> Error ("invalid trace_id in persisted keeper identity: " ^ err))
  with
  | Error e -> Error ("keeper meta parse error: " ^ e)
  | Ok pk_trace_id ->
    let pk_trace_history =
      Safe_ops.json_string_list "trace_history" json |> List.filter validate_name
    in
    let pk_goal =
      Safe_ops.json_string ~default:"" "goal" json |> normalize_goal_horizon_text
    in
    let pk_short_goal, pk_mid_goal, pk_long_goal =
      resolve_goal_horizons
        ~goal:pk_goal
        ~short_goal_opt:
          (normalize_goal_horizon_opt (Safe_ops.json_string_opt "short_goal" json))
        ~mid_goal_opt:
          (normalize_goal_horizon_opt (Safe_ops.json_string_opt "mid_goal" json))
        ~long_goal_opt:
          (normalize_goal_horizon_opt (Safe_ops.json_string_opt "long_goal" json))
    in
    let pk_social_model =
      Safe_ops.json_string
        ~default:(Env_config_core.keeper_social_model ())
        "social_model"
        json
    in
    (* Layer 2 PR-B (commit 5): delegate the four personality fields
       to [Keeper_personality_io].  parse + coerce yields trim-only
       canonicalisation; truncation moved to the prompt-render path
       (Keeper_prompt) so disk and in-memory stay byte-identical.
       Decision Resolution: write raw, compare normalize, render
       truncate. *)
    let personality_defaults : Keeper_personality_io.raw_personality =
      {
        will = Env_config_core.keeper_will ();
        needs = Env_config_core.keeper_needs ();
        desires = Env_config_core.keeper_desires ();
        instructions = "";
      }
    in
    let personality =
      Keeper_personality_io.parse ~defaults:personality_defaults json
      |> Keeper_personality_io.coerce |> Keeper_personality_io.to_raw
    in
    let pk_will = personality.will in
    let pk_needs = personality.needs in
    let pk_desires = personality.desires in
    let pk_instructions = personality.instructions in
    let pk_cascade_name =
      (* Preserve the raw cascade_name as persisted in runtime JSON so the
       dashboard can distinguish "declared in TOML" from "canonicalized
       fallback".  Downstream code canonicalizes at point-of-use. *)
      Safe_ops.json_string ~default:Keeper_config.default_cascade_name "cascade_name" json
    in
    let pk_models =
      match json |> Yojson.Safe.Util.member "models" with
      | `List items ->
        List.filter_map
          (function
            | `String s -> Some (String.trim s)
            | _ -> None)
          items
      | _ -> []
    in
    Ok
      { pk_name
      ; pk_agent_name
      ; pk_trace_id
      ; pk_trace_history
      ; pk_goal
      ; pk_short_goal
      ; pk_mid_goal
      ; pk_long_goal
      ; pk_social_model
      ; pk_cascade_name
      ; pk_cascade_ref =
        (match json |> Yojson.Safe.Util.member "cascade_ref" with
         | `Null | `Assoc [] -> None
         | ref_json ->
             (match Cascade_ref.cascade_ref_of_json ref_json with
              | Some ref -> Some ref
              | None -> Some (Cascade_ref.cascade_ref_of_string pk_cascade_name)))
      ; pk_models
      ; pk_will
      ; pk_needs
      ; pk_desires
      ; pk_instructions
      }
;;

(* Fail-loud sandbox policy field parsing.

   Prior to 2026-04-28 a missing [sandbox_profile] / [network_mode] in
   keeper_meta.json silently fell back to [default_sandbox_profile = Local]
   even when the keeper TOML declared [sandbox_profile = "docker"]. The
   silent fallback hid the divergence and routed Docker-intended keepers
   to host fork/exec. We now require both fields explicitly and direct the
   operator to the migration script for legacy meta files.

   Cross-validation of (profile, mode) is intentionally omitted: an
   operator that writes [sandbox_profile = "local"] with
   [network_mode = "none"] is in scope. The point of this gate is to
   refuse the *missing* and *unparseable* cases, not to second-guess
   legal combinations. *)
let parse_sandbox_policy_fields (json : Yojson.Safe.t)
  : (sandbox_profile * string option * network_mode, string) result
  =
  let ( let* ) = Result.bind in
  let* sp_raw =
    match Safe_ops.json_string_opt "sandbox_profile" json with
    | Some s -> Ok s
    | None ->
      Error
        "sandbox_profile required in keeper_meta.json (run \
         scripts/migrate-keeper-meta-sandbox.sh to normalize legacy meta files)"
  in
  let* sp =
    match sandbox_profile_of_string sp_raw with
    | Some p -> Ok p
    | None ->
      Error
        (Printf.sprintf
           "sandbox_profile %S is not a valid value (expected one of: %s)"
           sp_raw
           (String.concat ", " valid_sandbox_profile_strings))
  in
  let si = Safe_ops.json_string_opt "sandbox_image" json in
  let* nm_raw =
    match Safe_ops.json_string_opt "network_mode" json with
    | Some s -> Ok s
    | None ->
      Error
        "network_mode required in keeper_meta.json (run \
         scripts/migrate-keeper-meta-sandbox.sh to normalize legacy meta files)"
  in
  let* nm =
    match network_mode_of_string nm_raw with
    | Some m -> Ok m
    | None ->
      Error
        (Printf.sprintf
           "network_mode %S is not a valid value (expected one of: %s)"
           nm_raw
           (String.concat ", " valid_network_mode_strings))
  in
  Ok (sp, si, nm)
;;

let parse_keeper_policy (json : Yojson.Safe.t) ~(keeper_name : string)
  : (parsed_keeper_policy, string) result
  =
  let voice_enabled_default = default_voice_enabled_for keeper_name in
  match tool_access_of_meta_json json with
  | Error msg -> Error ("meta parse error: " ^ msg)
  | Ok pp_tool_access ->
    (match parse_sandbox_policy_fields json with
     | Error msg -> Error ("meta parse error: " ^ msg)
     | Ok (pp_sandbox_profile, pp_sandbox_image, pp_network_mode) ->
    let pp_policy_voice_enabled =
      Safe_ops.json_bool ~default:voice_enabled_default "policy_voice_enabled" json
    in
    let pp_allowed_paths = Safe_ops.json_string_list "allowed_paths" json in
    let pp_tool_denylist = Safe_ops.json_string_list "tool_denylist" json in
    let pp_mention_targets =
      Safe_ops.json_string_list "mention_targets" json |> dedupe_keep_order
    in
    let pp_room_signal_prompt_enabled =
      Safe_ops.json_bool
        ~default:default_room_signal_prompt_enabled
        "room_signal_prompt_enabled"
        json
    in
    let pp_joined_room_ids =
      Safe_ops.json_string_list "joined_room_ids" json
      |> List.filter validate_name
      |> dedupe_keep_order
    in
    let pp_last_seen_seq_by_room =
      Yojson.Safe.Util.member "last_seen_seq_by_room" json |> room_seq_map_of_json
    in
    let proactive_enabled =
      Safe_ops.json_bool ~default:default_proactive_enabled "proactive_enabled" json
    in
    let proactive_idle_sec =
      Safe_ops.json_int ~default:default_proactive_idle_sec "proactive_idle_sec" json
      |> normalize_proactive_idle_sec
    in
    let proactive_cooldown_sec =
      Safe_ops.json_int
        ~default:default_proactive_cooldown_sec
        "proactive_cooldown_sec"
        json
      |> normalize_proactive_cooldown_sec
    in
    let env_ratio_gate, env_message_gate, env_token_gate =
      keeper_compaction_policy_from_env ()
    in
    let compaction_profile =
      Safe_ops.json_string ~default:default_compaction_profile "compaction_profile" json
      |> canonical_compaction_profile
      |> Option.value ~default:default_compaction_profile
    in
    let compaction_ratio_gate =
      Safe_ops.json_float ~default:env_ratio_gate "compaction_ratio_gate" json
      |> normalize_compaction_ratio_gate
    in
    let compaction_message_gate =
      Safe_ops.json_int ~default:env_message_gate "compaction_message_gate" json
      |> normalize_compaction_message_gate
    in
    let compaction_token_gate =
      Safe_ops.json_int ~default:env_token_gate "compaction_token_gate" json
      |> normalize_compaction_token_gate
    in
    let continuity_compaction_cooldown_sec =
      Safe_ops.json_int
        ~default:(keeper_continuity_compaction_cooldown_sec ())
        "continuity_compaction_cooldown_sec"
        json
      |> normalize_continuity_compaction_cooldown_sec
    in
    let pp_auto_handoff = Safe_ops.json_bool ~default:true "auto_handoff" json in
    let pp_handoff_threshold =
      Safe_ops.json_float ~default:0.85 "handoff_threshold" json
    in
    let pp_handoff_cooldown_sec =
      Safe_ops.json_int ~default:300 "handoff_cooldown_sec" json
    in
    let pp_voice_enabled =
      Safe_ops.json_bool ~default:voice_enabled_default "voice_enabled" json
    in
    let pp_voice_channel =
      Safe_ops.json_string
        ~default:(default_voice_channel_for keeper_name)
        "voice_channel"
        json
      |> canonical_voice_channel
    in
    let pp_voice_agent_id =
      Safe_ops.json_string
        ~default:(default_voice_agent_id_for keeper_name)
        "voice_agent_id"
        json
    in
    let pp_per_provider_timeout_s =
      normalize_per_provider_timeout_json_field
        ~source:(Printf.sprintf "keeper meta %s" keeper_name)
        ~field:"per_provider_timeout_s"
        json
    in
    let pp_always_approve = Safe_ops.json_bool_opt "always_approve" json in
    Ok
      { pp_policy_voice_enabled
      ; pp_sandbox_profile
      ; pp_sandbox_image
      ; pp_network_mode
      ; pp_allowed_paths
      ; pp_tool_access
      ; pp_tool_denylist
      ; pp_mention_targets
      ; pp_room_signal_prompt_enabled
      ; pp_joined_room_ids
      ; pp_last_seen_seq_by_room
      ; pp_proactive =
          { enabled = proactive_enabled
          ; idle_sec = proactive_idle_sec
          ; cooldown_sec = proactive_cooldown_sec
          }
      ; pp_compaction =
          { profile = compaction_profile
          ; ratio_gate = compaction_ratio_gate
          ; message_gate = compaction_message_gate
          ; token_gate = compaction_token_gate
          ; cooldown_sec = continuity_compaction_cooldown_sec
          ; max_checkpoint_messages =
              Safe_ops.json_int ~default:120 "max_checkpoint_messages" json
          }
      ; pp_auto_handoff
      ; pp_handoff_threshold
      ; pp_handoff_cooldown_sec
      ; pp_voice_enabled
      ; pp_voice_channel
      ; pp_voice_agent_id
      ; pp_per_provider_timeout_s
      ; pp_always_approve
      })
;;

let parse_usage_metrics (json : Yojson.Safe.t) : usage_metrics =
  { total_turns = Safe_ops.json_int ~default:0 "total_turns" json
  ; total_input_tokens = Safe_ops.json_int ~default:0 "total_input_tokens" json
  ; total_output_tokens = Safe_ops.json_int ~default:0 "total_output_tokens" json
  ; total_tokens = Safe_ops.json_int ~default:0 "total_tokens" json
  ; total_cost_usd = Safe_ops.json_float ~default:0.0 "total_cost_usd" json
  ; last_turn_ts = Safe_ops.json_float ~default:0.0 "last_turn_ts" json
  ; last_model_used = Safe_ops.json_string ~default:"" "last_model_used" json
  ; last_input_tokens = Safe_ops.json_int ~default:0 "last_input_tokens" json
  ; last_output_tokens = Safe_ops.json_int ~default:0 "last_output_tokens" json
  ; last_total_tokens = Safe_ops.json_int ~default:0 "last_total_tokens" json
  ; last_latency_ms = Safe_ops.json_int ~default:0 "last_latency_ms" json
  }
;;

let parse_compaction_runtime (json : Yojson.Safe.t) : compaction_runtime =
  { count = Safe_ops.json_int ~default:0 "compaction_count" json
  ; last_ts = Safe_ops.json_float ~default:0.0 "last_compaction_ts" json
  ; last_before_tokens = Safe_ops.json_int ~default:0 "last_compaction_before_tokens" json
  ; last_after_tokens = Safe_ops.json_int ~default:0 "last_compaction_after_tokens" json
  ; last_check_ts = Safe_ops.json_float ~default:0.0 "last_compaction_check_ts" json
  ; last_decision =
      Safe_ops.json_string ~default:"uninitialized" "last_compaction_decision" json
      |> compaction_runtime_decision_of_string
  }
;;

let parse_proactive_runtime (json : Yojson.Safe.t) : proactive_runtime =
  let count_total = Safe_ops.json_int ~default:0 "proactive_count_total" json in
  let last_ts = Safe_ops.json_float ~default:0.0 "last_proactive_ts" json in
  { count_total
  ; last_ts
  ; visible_count_total =
      Safe_ops.json_int ~default:0 "proactive_visible_count_total" json
  ; last_visible_ts = Safe_ops.json_float ~default:0.0 "last_visible_proactive_ts" json
  ; last_outcome =
      Safe_ops.json_string_opt "last_proactive_outcome" json
      |> Option.value ~default:"unknown"
      |> proactive_cycle_outcome_of_string
  ; last_reason = Safe_ops.json_string ~default:"" "last_proactive_reason" json
  ; last_preview = Safe_ops.json_string ~default:"" "last_proactive_preview" json
  ; last_work_discovery_ts =
      Safe_ops.json_float ~default:0.0 "last_work_discovery_ts" json
  ; work_discovery_count = Safe_ops.json_int ~default:0 "work_discovery_count" json
  ; consecutive_noop_count = Safe_ops.json_int ~default:0 "consecutive_noop_count" json
  }
;;

let parse_last_continuity_update_ts ~(continuity_summary : string) (json : Yojson.Safe.t) =
  let parsed_ts = Safe_ops.json_float ~default:0.0 "last_continuity_update_ts" json in
  if parsed_ts <= 0.0 && String.trim continuity_summary <> ""
  then Time_compat.now ()
  else parsed_ts
;;

let parse_keeper_state
      (json : Yojson.Safe.t)
      ~(trace_id : Keeper_id.Trace_id.t)
      ~(trace_history : string list)
  : parsed_keeper_state
  =
  let generation = Safe_ops.json_int ~default:0 "generation" json in
  let last_handoff_ts = Safe_ops.json_float ~default:0.0 "last_handoff_ts" json in
  let ps_created_at_raw = Safe_ops.json_string ~default:"" "created_at" json in
  let ps_updated_at_raw = Safe_ops.json_string ~default:"" "updated_at" json in
  let ps_continuity_summary =
    Safe_ops.json_string ~default:"" "continuity_summary" json
  in
  let last_continuity_update_ts =
    parse_last_continuity_update_ts ~continuity_summary:ps_continuity_summary json
  in
  let ps_active_goal_ids = Safe_ops.json_string_list "active_goal_ids" json in
  let last_autonomous_action_at =
    Safe_ops.json_string ~default:"" "last_autonomous_action_at" json
  in
  let autonomous_action_count =
    Safe_ops.json_int ~default:0 "autonomous_action_count" json
  in
  let autonomous_turn_count = Safe_ops.json_int ~default:0 "autonomous_turn_count" json in
  let autonomous_text_turn_count =
    Safe_ops.json_int ~default:0 "autonomous_text_turn_count" json
  in
  let autonomous_tool_turn_count =
    Safe_ops.json_int ~default:0 "autonomous_tool_turn_count" json
  in
  let board_reactive_turn_count =
    Safe_ops.json_int ~default:0 "board_reactive_turn_count" json
  in
  let mention_reactive_turn_count =
    Safe_ops.json_int ~default:0 "mention_reactive_turn_count" json
  in
  let noop_turn_count = Safe_ops.json_int ~default:0 "noop_turn_count" json in
  let consecutive_noop_count =
    Safe_ops.json_int ~default:0 "consecutive_noop_count" json
  in
  let last_speech_act = Safe_ops.json_string ~default:"" "last_speech_act" json in
  let last_social_transition_reason =
    Safe_ops.json_string ~default:"" "last_social_transition_reason" json
  in
  (* Gen12: cap narrative fields on load so pre-Gen8 checkpoints
     (written before the write-side cap) cannot bleed unbounded
     strings back into meta.runtime. Same budget as cap_social_state. *)
  let cap_loaded =
    Keeper_social_model_types.truncate_string
      ~max_chars:Keeper_social_model_types.default_option_field_max_chars
  in
  let last_active_desire =
    cap_loaded (Safe_ops.json_string ~default:"" "last_active_desire" json)
  in
  let last_current_intention =
    cap_loaded (Safe_ops.json_string ~default:"" "last_current_intention" json)
  in
  (* #9933: blocker may carry a structured [masc_oas_error] JSON
     payload. cap_loaded (narrative budget = 200 chars) would slice
     the JSON mid-key and lose diagnostic fields (budget_sec,
     keeper_turn_timeout_sec, estimated_input_tokens, source).
     cap_blocker preserves structured payloads up to
     masc_oas_error_max_chars and falls through to the narrative
     budget for plain text. Symmetric with the write side in
     Keeper_social_model_types.cap_social_state. *)
  (* New format: last_blocker is a structured object (blocker_info_to_json
     output) or `Null.  Legacy format had two fields: last_blocker:string
     and last_blocker_class:string|null.  We accept both shapes for one-shot
     read migration; the next write upgrades to the new format. *)
  let last_blocker =
    let raw_field = Yojson.Safe.Util.member "last_blocker" json in
    match raw_field with
    | `Null -> None
    | `Assoc _ -> blocker_info_of_json raw_field
    | `String legacy_text ->
      let detail =
        Keeper_social_model_types.cap_blocker (String.trim legacy_text)
      in
      let klass_from_pair =
        match Safe_ops.json_string_opt "last_blocker_class" json with
        | Some raw -> blocker_class_of_serialized_string raw
        | None -> None
      in
      (match klass_from_pair with
       | Some klass -> Some { klass; detail }
       | None -> None)
    | _ -> None
  in
  let last_need = cap_loaded (Safe_ops.json_string ~default:"" "last_need" json) in
  let ps_paused = Safe_ops.json_bool ~default:false "paused" json in
  let ps_auto_resume_after_sec = Safe_ops.json_float_opt "auto_resume_after_sec" json in
  let ps_autoboot_enabled = Safe_ops.json_bool ~default:true "autoboot_enabled" json in
  let ps_current_task_id =
    match Safe_ops.json_string_opt "current_task_id" json with
    | None -> None
    | Some s ->
      (match Keeper_id.Task_id.of_string s with
       | Ok tid -> Some tid
       | Error _ -> None)
  in
  let ps_max_context_override = Safe_ops.json_int_opt "max_context_override" json in
  { ps_created_at_raw
  ; ps_updated_at_raw
  ; ps_continuity_summary
  ; ps_active_goal_ids
  ; ps_paused
  ; ps_auto_resume_after_sec
  ; ps_autoboot_enabled
  ; ps_current_task_id
  ; ps_max_context_override
  ; ps_runtime =
      { usage = parse_usage_metrics json
      ; compaction_rt = parse_compaction_runtime json
      ; proactive_rt = parse_proactive_runtime json
      ; generation
      ; trace_id
      ; trace_history
      ; last_handoff_ts
      ; last_continuity_update_ts
      ; last_autonomous_action_at
      ; autonomous_action_count
      ; autonomous_turn_count
      ; autonomous_text_turn_count
      ; autonomous_tool_turn_count
      ; board_reactive_turn_count
      ; mention_reactive_turn_count
      ; noop_turn_count
      ; consecutive_noop_count
      ; last_speech_act
      ; last_social_transition_reason
      ; last_active_desire
      ; last_current_intention
      ; last_blocker
      ; last_need
      }
  }
;;

let meta_of_json (json : Yojson.Safe.t) : (keeper_meta, string) result =
  try
    match reject_removed_keeper_meta_fields json with
    | Error e -> Error e
    | Ok () ->
      (match reject_legacy_keeper_meta_fields json with
       | Error e -> Error e
       | Ok () ->
         (match parse_keeper_identity json with
          | Error _ as e -> e
          | Ok identity ->
            (match parse_keeper_policy json ~keeper_name:identity.pk_name with
             | Error _ as e -> e
             | Ok policy ->
               let state =
                 parse_keeper_state
                   json
                   ~trace_id:identity.pk_trace_id
                   ~trace_history:identity.pk_trace_history
               in
               if not (validate_name identity.pk_name)
               then Error "invalid keeper meta (bad name)"
               else if
                 not (validate_name (Keeper_id.Trace_id.to_string identity.pk_trace_id))
               then Error "invalid keeper meta (bad trace_id)"
               else
                 Ok
                   { id = None
                   ; name = identity.pk_name
                   ; agent_name =
                       (if identity.pk_agent_name = ""
                        then keeper_agent_name identity.pk_name
                        else identity.pk_agent_name)
                   ; goal = identity.pk_goal
                   ; short_goal = identity.pk_short_goal
                   ; mid_goal = identity.pk_mid_goal
                   ; long_goal = identity.pk_long_goal
                   ; social_model = identity.pk_social_model
                   ; cascade_ref =
                       (match identity.pk_cascade_ref with
                        | Some _ as ref_ -> ref_
                        | None ->
                            (* RFC-0041: derive cascade_ref from legacy
                               cascade_name string when persisted JSON
                               predates the field. *)
                            Some Cascade_ref.{
                              group = identity.pk_cascade_name;
                              item = None;
                            })
                   ; models = identity.pk_models
                   ; will = identity.pk_will
                   ; needs = identity.pk_needs
                   ; desires = identity.pk_desires
                   ; instructions = identity.pk_instructions
                   ; policy_voice_enabled = policy.pp_policy_voice_enabled
                   ; sandbox_profile = policy.pp_sandbox_profile
                   ; sandbox_image = policy.pp_sandbox_image
                   ; network_mode = policy.pp_network_mode
                   ; allowed_paths = policy.pp_allowed_paths
                   ; tool_access = policy.pp_tool_access
                   ; tool_preset_source =
                       Safe_ops.json_string_opt "tool_preset_source" json
                   ; tool_denylist = policy.pp_tool_denylist
                   ; mention_targets = policy.pp_mention_targets
                   ; room_signal_prompt_enabled = policy.pp_room_signal_prompt_enabled
                   ; joined_room_ids = policy.pp_joined_room_ids
                   ; last_seen_seq_by_room = policy.pp_last_seen_seq_by_room
                   ; proactive = policy.pp_proactive
                   ; compaction = policy.pp_compaction
                   ; auto_handoff = policy.pp_auto_handoff
                   ; handoff_threshold = policy.pp_handoff_threshold
                   ; handoff_cooldown_sec = policy.pp_handoff_cooldown_sec
                   ; voice_enabled = policy.pp_voice_enabled
                   ; voice_channel = policy.pp_voice_channel
                   ; voice_agent_id = policy.pp_voice_agent_id
                   ; per_provider_timeout_s = policy.pp_per_provider_timeout_s
                   ; always_approve = policy.pp_always_approve
                   ; created_at =
                       (if state.ps_created_at_raw = ""
                        then now_iso ()
                        else state.ps_created_at_raw)
                   ; updated_at =
                       (if state.ps_updated_at_raw = ""
                        then now_iso ()
                        else state.ps_updated_at_raw)
                   ; continuity_summary = state.ps_continuity_summary
                   ; active_goal_ids = state.ps_active_goal_ids
                   ; paused = state.ps_paused
                   ; auto_resume_after_sec = state.ps_auto_resume_after_sec
                   ; autoboot_enabled = state.ps_autoboot_enabled
                   ; current_task_id = state.ps_current_task_id
                   ; max_context_override = state.ps_max_context_override
                   ; work_discovery_enabled =
                       Safe_ops.json_bool_opt "work_discovery_enabled" json
                   ; work_discovery_sources =
                       (match json with
                        | `Assoc fields ->
                          (match List.assoc_opt "work_discovery_sources" fields with
                           | Some (`List items) ->
                             Some
                               (List.filter_map
                                  (function
                                    | `String s -> Some s
                                    | _ -> None)
                                  items)
                           | _ -> None)
                        | _ -> None)
                   ; work_discovery_interval_sec =
                       Safe_ops.json_int_opt "work_discovery_interval_sec" json
                   ; work_discovery_guidance =
                       Safe_ops.json_string_opt "work_discovery_guidance" json
                   ; telemetry_feedback_enabled =
                       Safe_ops.json_bool_opt "telemetry_feedback_enabled" json
                   ; telemetry_feedback_window_hours =
                       Safe_ops.json_int_opt "telemetry_feedback_window_hours" json
                   ; runtime = state.ps_runtime
                   ; oas_env =
                       (match Yojson.Safe.Util.member "oas_env" json with
                        | `Assoc fields ->
                          List.filter_map
                            (function
                              | k, `String v -> Some (k, v)
                              | _ -> None)
                            fields
                        | _ -> [])
                   ; keeper_id =
                       (match Safe_ops.json_string_opt "keeper_id" json with
                        | Some s ->
                          (match Keeper_id.uid_of_yojson (`String s) with
                           | Ok uid -> Some uid
                           | Error _ -> None)
                        | None -> None)
                   ; meta_version =
                       (match Safe_ops.json_int_opt "meta_version" json with
                        | Some v -> v
                        | None -> 0)
                   })))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "meta parse error: %s" (Printexc.to_string exn))
;;
