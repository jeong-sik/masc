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
  ; pk_persona : string option
  ; pk_trace_id : Keeper_id.Trace_id.t
  ; pk_trace_history : string list
  ; pk_instructions : string
  }

type parsed_keeper_policy =
  { pp_sandbox_profile : sandbox_profile
  ; pp_sandbox_image : string option
  ; pp_network_mode : network_mode
  ; pp_allowed_paths : string list
  ; pp_mention_targets : string list
  ; pp_proactive : proactive_policy
  ; pp_compaction : compaction_policy
  ; pp_auto_handoff : bool
  ; pp_handoff_threshold : float
  ; pp_handoff_cooldown_sec : int
  ; pp_always_allow : bool option
  }

type parsed_keeper_state =
  { ps_created_at_raw : string
  ; ps_updated_at_raw : string
  ; ps_active_goal_ids : string list
  ; ps_paused : bool
  ; ps_latched_reason : Keeper_latched_reason.t option
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
    let pk_persona = Safe_ops.json_string_opt "persona" json in
    let pk_trace_history =
      Safe_ops.json_string_list "trace_history" json |> List.filter validate_name
    in
    (* Layer 2 PR-B (commit 5): delegate the surviving personality field
       to [Keeper_personality_io].  parse + coerce yields trim-only
       canonicalisation; truncation moved to the prompt-render path
       (Keeper_prompt) so disk and in-memory stay byte-identical.
       Decision Resolution: write raw, compare normalize, render
       truncate. *)
    let personality =
      Keeper_personality_io.parse json
      |> Keeper_personality_io.coerce |> Keeper_personality_io.to_raw
    in
    let pk_instructions = personality.instructions in
    Ok
      { pk_name
      ; pk_agent_name
      ; pk_persona
      ; pk_trace_id
      ; pk_trace_history
      ; pk_instructions
      }
;;

(* Fail-loud sandbox policy field parsing.

   Config fields (sandbox_profile, network_mode) are now TOML-only; runtime
   JSON omits them by design.  When absent, we return defaults so that
   [ensure_keeper_meta] can overlay the TOML SSOT values.  Invalid values
   are still rejected — only the *missing* case changed from Error to
   default. *)
let parse_sandbox_policy_fields (json : Yojson.Safe.t)
  : (sandbox_profile * string option * network_mode, string) result
  =
  let sp =
    match Safe_ops.json_string_opt "sandbox_profile" json with
    | None -> default_sandbox_profile
    | Some sp_raw ->
      (match sandbox_profile_of_string sp_raw with
       | Some p -> p
       | None -> default_sandbox_profile)
  in
  let si = Safe_ops.json_string_opt "sandbox_image" json in
  let nm =
    match Safe_ops.json_string_opt "network_mode" json with
    | None -> default_network_mode_for_profile sp
    | Some nm_raw ->
      (match network_mode_of_string nm_raw with
       | Some m -> m
       | None -> default_network_mode_for_profile sp)
  in
  Ok (sp, si, nm)
;;

let parse_keeper_policy (json : Yojson.Safe.t) ~(keeper_name : string)
  : (parsed_keeper_policy, string) result
  =
  match parse_sandbox_policy_fields json with
  | Error msg -> Error ("meta parse error: " ^ msg)
  | Ok (pp_sandbox_profile, pp_sandbox_image, pp_network_mode) ->
    (* TOML-only config fields: the write side ([keeper_meta_json.ml]) omits
       these by design, so the runtime JSON never carries them. The parser no
       longer reads them — [ensure_keeper_meta] overlays the TOML SSOT value.
       Neutral placeholders here keep the record total; a legacy JSON that still
       carries one of these keys is ignored (TOML remains authoritative). *)
    let pp_allowed_paths = [] in
    let pp_mention_targets = [] in
    let proactive_enabled = default_proactive_enabled in
    let env_ratio_gate, env_message_gate, env_token_gate =
      keeper_compaction_policy_from_env ()
    in
    let compaction_profile =
      Safe_ops.json_string ~default:default_compaction_profile "compaction_profile" json
      |> canonical_compaction_profile
      |> Option.value ~default:default_compaction_profile
    in
    (* [compaction_mode] parses fail-closed: absent → env default; present but
       invalid → parse error. A persisted typo must not silently inherit the
       environment/default mode. *)
    let compaction_mode =
      match Safe_ops.json_string_opt "compaction_mode" json with
      | None -> Ok (Keeper_config.keeper_compaction_mode_default ())
      | Some raw ->
        (match Keeper_config.compaction_mode_of_string raw with
         | Ok mode -> Ok mode
         | Error msg -> Error ("invalid persisted compaction_mode: " ^ msg))
    in
    match compaction_mode with
    | Error msg -> Error ("meta parse error: " ^ msg)
    | Ok compaction_mode ->
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
    let compaction_cooldown_sec =
      Safe_ops.json_int
        ~default:(keeper_compaction_cooldown_sec ())
        "compaction_cooldown_sec"
        json
      |> normalize_compaction_cooldown_sec
    in
    let pp_auto_handoff = Safe_ops.json_bool ~default:true "auto_handoff" json in
    let pp_handoff_threshold =
      Safe_ops.json_float ~default:0.85 "handoff_threshold" json
    in
    let pp_handoff_cooldown_sec =
      Safe_ops.json_int ~default:300 "handoff_cooldown_sec" json
    in
    let pp_always_allow = None in
    (* TOML-only (see note above); overlaid by [ensure_keeper_meta]. *)
    Ok
      { pp_sandbox_profile
      ; pp_sandbox_image
      ; pp_network_mode
      ; pp_allowed_paths
      ; pp_mention_targets
      ; pp_proactive = { enabled = proactive_enabled }
      ; pp_compaction =
          { profile = compaction_profile
          ; mode = compaction_mode
          ; ratio_gate = compaction_ratio_gate
          ; message_gate = compaction_message_gate
          ; token_gate = compaction_token_gate
          ; cooldown_sec = compaction_cooldown_sec
          }
      ; pp_auto_handoff
      ; pp_handoff_threshold
      ; pp_handoff_cooldown_sec
      ; pp_always_allow
      }
;;

let parse_usage_metrics (json : Yojson.Safe.t) : usage_metrics =
  { total_turns = Safe_ops.json_int ~default:0 "total_turns" json
  ; total_input_tokens = Safe_ops.json_int ~default:0 "total_input_tokens" json
  ; total_output_tokens = Safe_ops.json_int ~default:0 "total_output_tokens" json
  ; total_tokens = Safe_ops.json_int ~default:0 "total_tokens" json
  ; total_cost_usd = Safe_ops.json_float ~default:0.0 "total_cost_usd" json
  ; last_turn_ts = Safe_ops.json_float ~default:0.0 "last_turn_ts" json
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
  ; last_operation_id = Safe_ops.json_string_opt "last_compaction_operation_id" json
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
  ; consecutive_noop_count = Safe_ops.json_int ~default:0 "consecutive_noop_count" json
  }
;;

let parse_keeper_state
      (json : Yojson.Safe.t)
      ~(trace_id : Keeper_id.Trace_id.t)
      ~(trace_history : string list)
      ~(keeper_name : string)
  : parsed_keeper_state
  =
  (match Json_util.assoc_member_opt "auto_resume_after_sec" json with
   | None -> ()
   | Some _ ->
     Log.Keeper.warn
       "%s: retired auto_resume_after_sec persisted field requires canonical \
        metadata migration; paused state is preserved and only an explicit \
        operator resume may clear it"
       keeper_name;
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string MetaReadFailures)
       ~labels:
         [ "keeper", keeper_name
         ; "site", "retired_auto_resume_field_migration_needed"
         ]
       ());
  let generation = Safe_ops.json_int ~default:0 "generation" json in
  let last_handoff_ts = Safe_ops.json_float ~default:0.0 "last_handoff_ts" json in
  let ps_created_at_raw = Safe_ops.json_string ~default:"" "created_at" json in
  let ps_updated_at_raw = Safe_ops.json_string ~default:"" "updated_at" json in
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
  let message_scope_ack_id = Safe_ops.json_string_opt "message_scope_ack_id" json in
  (* Canonical format: last_blocker is a structured object
     (blocker_info_to_json output) or `Null. *)
  let last_blocker =
    let raw_field = Json_util.assoc_member_opt "last_blocker" json in
    match raw_field with
    | Some `Null -> None
    | Some (`Assoc _ as json) -> blocker_info_of_json json
    | _ -> None
	  in
	  let last_turn_tool_calls =
	    match json with
	    | `Assoc fields ->
	      (match List.assoc_opt "last_turn_tool_calls" fields with
	       | Some (`List items) ->
	         List.filter_map
	           (function
	            | `Assoc [ ("tool_name", `String n); ("outcome", `String o) ] ->
	              Some { Keeper_meta_contract.tool_name = n; outcome = o }
	            | _ -> None)
	           items
	       | _ -> [])
	    | _ -> []
	  in
	  let last_runtime_attempt =
	    match json with
	    | `Assoc fields ->
	      (match List.assoc_opt "last_runtime_attempt" fields with
	       | Some raw -> runtime_attempt_record_of_json raw
	       | None -> None)
	    | _ -> None
	  in
	  let ps_paused = Safe_ops.json_bool ~default:false "paused" json in
  (* [paused] is the authoritative pause bit. [latched_reason] refines the
     lifecycle state, notably distinguishing a terminal [Dead_tombstone]. A
     malformed/unknown value degrades to [None] without clearing [paused];
     lifecycle admission therefore treats that combination as an unclassified
     pause. Degradation is logged and counted so the lost classification is
     visible rather than silently activating the keeper. *)
  let ps_latched_reason =
    match Json_util.assoc_member_opt "latched_reason" json with
    | None | Some `Null -> None
    | Some reason_json ->
      (match Keeper_latched_reason.Stable.of_yojson reason_json with
       | Ok reason -> Some reason
       | Error err ->
         Log.Keeper.warn
           "%s: malformed latched_reason JSON dropped: %s"
           keeper_name
           err;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string MetaReadFailures)
           ~labels:[ "keeper", keeper_name; "site", "latched_reason_parse" ]
           ();
         None)
  in
  (* TOML-only config; overlaid by [ensure_keeper_meta]. Placeholder default. *)
  let ps_autoboot_enabled = true in
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
  ; ps_active_goal_ids
  ; ps_paused
  ; ps_latched_reason
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
      ; last_autonomous_action_at
      ; autonomous_action_count
      ; autonomous_turn_count
      ; autonomous_text_turn_count
      ; autonomous_tool_turn_count
      ; board_reactive_turn_count
      ; mention_reactive_turn_count
      ; noop_turn_count
      ; message_scope_ack_id
	      ; last_blocker
	      ; last_runtime_attempt
	      ; last_turn_tool_calls
	      }
  }
;;

type removed_keeper_meta_field =
  | Legacy_goal
  | Initiative_enabled
  | Persona_profile_path
  | Tool_access
  | Tool_denylist
  | Policy_voice_enabled
  | Last_blocker

let removed_keeper_meta_field_of_key = function
  | "goal" -> Some Legacy_goal
  | "initiative_enabled" -> Some Initiative_enabled
  | "persona_profile_path" -> Some Persona_profile_path
  | "tool_access" -> Some Tool_access
  | "tool_denylist" -> Some Tool_denylist
  | "policy_voice_enabled" -> Some Policy_voice_enabled
  | "last_blocker" -> Some Last_blocker
  | _ -> None
;;

let removed_keeper_meta_field_to_wire = function
  | Legacy_goal -> "goal"
  | Initiative_enabled -> "initiative_enabled"
  | Persona_profile_path -> "persona_profile_path"
  | Tool_access -> "tool_access"
  | Tool_denylist -> "tool_denylist"
  | Policy_voice_enabled -> "policy_voice_enabled"
  | Last_blocker -> "last_blocker"
;;

let reject_removed_keeper_meta_shapes (json : Yojson.Safe.t) =
  let rec duplicate_key seen = function
    | [] -> None
    | (k, _) :: rest ->
      if List.exists (String.equal k) seen then Some k else duplicate_key (k :: seen) rest
  in
  let rec removed_field_error = function
    | [] -> Ok ()
    | (key, value) :: rest ->
      (match removed_keeper_meta_field_of_key key with
       | Some (Legacy_goal as field)
       | Some (Initiative_enabled as field)
       | Some (Persona_profile_path as field)
       | Some (Tool_access as field)
       | Some (Tool_denylist as field)
       | Some (Policy_voice_enabled as field) ->
         Error
           ( "removed keeper meta field is no longer supported: "
             ^ removed_keeper_meta_field_to_wire field )
       | Some Last_blocker ->
         (match value with
          | `String _ ->
            Error
              "removed keeper meta field shape is no longer supported: \
               last_blocker:string. Use structured last_blocker object."
          | _ -> removed_field_error rest)
       | None -> removed_field_error rest)
  in
  match json with
  | `Assoc fields ->
    (match duplicate_key [] fields with
     | Some k -> Error ("duplicate keeper meta field is not supported: " ^ k)
     | None -> removed_field_error fields)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> Ok ()
;;

let meta_of_json (json : Yojson.Safe.t) : (keeper_meta, string) result =
  try
    match reject_removed_keeper_meta_shapes json with
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
                   ~keeper_name:identity.pk_name
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
                        then Keeper_identity.keeper_agent_name identity.pk_name
                        else identity.pk_agent_name)
                   ; persona = identity.pk_persona
                   ; instructions = identity.pk_instructions
                   ; sandbox_profile = policy.pp_sandbox_profile
                   ; sandbox_image = policy.pp_sandbox_image
                   ; network_mode = policy.pp_network_mode
                   ; allowed_paths = policy.pp_allowed_paths
                   ; mention_targets = policy.pp_mention_targets
                   ; proactive = policy.pp_proactive
                   ; compaction = policy.pp_compaction
                   ; (* RFC vision-delegation §2.4. Parsed inline (mirrors the
                        telemetry fields below): unknown/missing -> default
                        Inherit (fail-closed, safe-by-default). This round-trips
                        through the checkpoint JSON so a Delegate keeper stays
                        Delegate across reload. *)
                     multimodal_policy =
                       (match Safe_ops.json_string_opt "multimodal_policy" json with
                        | Some raw ->
                          (match multimodal_policy_of_string raw with
                           | Some p -> p
                           | None -> default_multimodal_policy)
                        | None -> default_multimodal_policy)
                   ; auto_handoff = policy.pp_auto_handoff
                   ; handoff_threshold = policy.pp_handoff_threshold
                   ; handoff_cooldown_sec = policy.pp_handoff_cooldown_sec
                   ; always_allow = policy.pp_always_allow
                   ; created_at =
                       (if state.ps_created_at_raw = ""
                        then now_iso ()
                        else state.ps_created_at_raw)
                   ; updated_at =
                       (if state.ps_updated_at_raw = ""
                        then now_iso ()
                        else state.ps_updated_at_raw)
                   ; active_goal_ids = state.ps_active_goal_ids
                   ; paused = state.ps_paused
                   ; latched_reason = state.ps_latched_reason
                   ; autoboot_enabled = state.ps_autoboot_enabled
                   ; current_task_id = state.ps_current_task_id
                   ; max_context_override = state.ps_max_context_override
                     (* TOML-only config; overlaid by [ensure_keeper_meta]. *)
                   ; telemetry_feedback_enabled = None
                   ; telemetry_feedback_window_hours = None
                   ; runtime = state.ps_runtime
                   ; oas_env =
                       (match Json_util.assoc_member_opt "oas_env" json with
                        | Some (`Assoc fields) ->
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
                   }))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "meta parse error: %s" (Printexc.to_string exn))
;;
