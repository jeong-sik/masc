(** Keeper_types — shared keeper contract, registry/store helpers,
    path resolution, and model-selection utilities. *)

(* Utility functions, canonical helpers, profile defaults, and dir helpers
   extracted to Keeper_types_profile *)
include Keeper_types_profile

(* -- Policy types (remain in keeper_meta top-level) -- *)

type compaction_policy =
  { profile : string
  ; ratio_gate : float
  ; message_gate : int
  ; token_gate : int
  ; cooldown_sec : int
  ; max_checkpoint_messages : int
  }

type proactive_policy =
  { enabled : bool
  ; idle_sec : int
  ; cooldown_sec : int
  }

type scheduled_autonomous_policy = proactive_policy

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error

type scheduled_autonomous_cycle_outcome = proactive_cycle_outcome

type tool_preset =
  | Minimal
  | Social
  | Messaging
  | Coding
  | Research
  | Delivery
  | Full

type tool_access =
  | Preset of
      { preset : tool_preset
      ; also_allow : string list
      }
  | Custom of string list

(* -- Runtime types (moved into agent_runtime_state) -- *)

type compaction_runtime =
  { count : int
  ; last_ts : float
  ; last_before_tokens : int
  ; last_after_tokens : int
  ; last_check_ts : float
  ; last_decision : string
  }

type proactive_runtime =
  { count_total : int
  ; last_ts : float
  ; visible_count_total : int
  ; last_visible_ts : float
  ; last_outcome : proactive_cycle_outcome
  ; last_reason : string
  ; last_preview : string
  ; last_work_discovery_ts : float
  ; work_discovery_count : int
  ; consecutive_noop_count : int
      (** Consecutive autonomous cycles where only observation tools
          (board_list, stay_silent, context_status) were used with no
          substantive action.  Resets to 0 on any productive cycle.
          Used by [effective_scheduled_autonomous_cooldown] for exponential
          backoff: cooldown *= 2^min(n, 3), capping at 8x. *)
  }

type scheduled_autonomous_runtime = proactive_runtime

type usage_metrics =
  { total_turns : int
  ; total_input_tokens : int
  ; total_output_tokens : int
  ; total_tokens : int
  ; total_cost_usd : float
  ; last_turn_ts : float
  ; last_model_used : string
  ; last_input_tokens : int
  ; last_output_tokens : int
  ; last_total_tokens : int
  ; last_latency_ms : int
  }

type agent_runtime_state =
  { usage : usage_metrics
  ; compaction_rt : compaction_runtime
  ; proactive_rt : proactive_runtime
  ; generation : int
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; last_handoff_ts : float
  ; last_continuity_update_ts : float
  ; last_autonomous_action_at : string
  ; autonomous_action_count : int
  ; autonomous_turn_count : int
  ; autonomous_text_turn_count : int
  ; autonomous_tool_turn_count : int
  ; board_reactive_turn_count : int
  ; mention_reactive_turn_count : int
  ; noop_turn_count : int
  ; consecutive_noop_count : int
  ; last_speech_act : string
  ; last_social_transition_reason : string
  ; last_active_desire : string
  ; last_current_intention : string
  ; last_blocker : string
  ; last_need : string
  }

type keeper_meta =
  { (* -- Identity & profile -- *)
    name : string
  ; agent_name : string
  ; goal : string
  ; short_goal : string
  ; mid_goal : string
  ; long_goal : string
  ; social_model : string
  ; cascade_name : string
  ; models : string list
  ; will : string
  ; needs : string
  ; desires : string
  ; instructions : string
  ; (* -- Policy -- *)
    policy_voice_enabled : bool
  ; execution_scope : Keeper_execution_scope.t
  ; allowed_paths : string list
  ; tool_access : tool_access
  ; tool_denylist : string list
  ; mention_targets : string list
  ; room_signal_prompt_enabled : bool
  ; joined_room_ids : string list
  ; last_seen_seq_by_room : (string * int) list
  ; proactive : proactive_policy
  ; compaction : compaction_policy
  ; auto_handoff : bool
  ; handoff_threshold : float
  ; handoff_cooldown_sec : int
  ; (* -- Voice -- *)
    voice_enabled : bool
  ; voice_channel : string
  ; voice_agent_id : string
  ; (* -- Lifecycle -- *)
    created_at : string
  ; updated_at : string
  ; (* -- Performance & Limits -- *)
    max_context_override : int option
  ; (* -- Operational control (top-level, not runtime) -- *)
    continuity_summary : string
  ; active_goal_ids : string list
  ; paused : bool
  ; autoboot_enabled : bool
  ; current_task_id : Keeper_id.Task_id.t option
    (** Currently claimed task ID for cost attribution.
      Set when keeper claims a task; cleared on masc_transition action=done.
      Propagated to trajectory accumulator for per-task cost tracking. *)
  ; work_discovery_enabled : bool option
  ; work_discovery_sources : string list option
  ; work_discovery_interval_sec : int option
  ; work_discovery_guidance : string option
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; (* -- Agent runtime state (usage, tracing, autonomy metrics) -- *)
    runtime : agent_runtime_state
  }

let default_social_model = "bdi_speech_v1"

let normalize_tool_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order
;;

let legacy_keeper_internal_tool_names =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal
;;

let legacy_session_min_tool_names =
  (* Legacy keepers historically received canonical masc_* coordination tools,
     not the SDK alias-heavy Session_min surface. Keep this compatibility list
     explicit so missing tool_access migration remains stable after tier removal. *)
  [
    "masc_status";
    "masc_tasks";
    "masc_claim_next";
    "masc_plan_set_task";
    "masc_transition";
    "masc_add_task";
    "masc_broadcast";
  ]

let migrate_legacy_restricted_tools names =
  Custom (normalize_tool_names (legacy_keeper_internal_tool_names @ names))
;;

let tool_preset_to_string = function
  | Minimal -> "minimal"
  | Social -> "social"
  | Messaging -> "messaging"
  | Coding -> "coding"
  | Research -> "research"
  | Delivery -> "delivery"
  | Full -> "full"
;;

let tool_preset_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "minimal" -> Some Minimal
  | "social" -> Some Social
  | "messaging" -> Some Messaging
  | "coding" -> Some Coding
  | "research" -> Some Research
  | "delivery" -> Some Delivery
  | "full" -> Some Full
  | _ -> None
;;

let proactive_cycle_outcome_to_string = function
  | Proactive_never_started -> "never_started"
  | Proactive_unknown -> "unknown"
  | Proactive_silent -> "silent"
  | Proactive_text_response -> "text_response"
  | Proactive_tool_use -> "tool_use"
  | Proactive_mixed_response -> "mixed_response"
  | Proactive_error -> "error"
;;

let proactive_cycle_outcome_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "never_started" -> Proactive_never_started
  | "silent" -> Proactive_silent
  | "text_response" -> Proactive_text_response
  | "tool_use" -> Proactive_tool_use
  | "mixed_response" -> Proactive_mixed_response
  | "error" -> Proactive_error
  | _ -> Proactive_unknown
;;

let scheduled_autonomous_cycle_outcome_to_string =
  proactive_cycle_outcome_to_string
;;

let scheduled_autonomous_cycle_outcome_of_string =
  proactive_cycle_outcome_of_string
;;

let normalize_tool_access = function
  | Preset { preset; also_allow } ->
    Preset { preset; also_allow = normalize_tool_names also_allow }
  | Custom names -> Custom (normalize_tool_names names)
;;

let tool_access_preset = function
  | Preset { preset; _ } -> Some preset
  | Custom _ -> None
;;

let tool_access_custom_allowlist = function
  | Preset _ -> None
  | Custom names -> Some names
;;

let tool_access_also_allowlist = function
  | Preset { also_allow; _ } -> also_allow
  | Custom _ -> []
;;

let tool_access_to_json access =
  match normalize_tool_access access with
  | Preset { preset; also_allow } ->
    `Assoc
      [ "kind", `String "preset"
      ; "preset", `String (tool_preset_to_string preset)
      ; "also_allow", `List (List.map (fun s -> `String s) also_allow)
      ]
  | Custom names ->
    `Assoc
      [ "kind", `String "custom"; "tools", `List (List.map (fun s -> `String s) names) ]
;;

let json_member_present key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false
;;

let string_list_field_result ?label ~field_name (json : Yojson.Safe.t) =
  let label = Option.value ~default:field_name label in
  match Yojson.Safe.Util.member field_name json with
  | `List items ->
    let rec collect acc index = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> collect (value :: acc) (index + 1) rest
      | _ :: _ -> Error (Printf.sprintf "keeper %s[%d] must be a string" label index)
    in
    collect [] 0 items
  | `Null -> Error (Printf.sprintf "keeper %s must be an array of strings" label)
  | _ -> Error (Printf.sprintf "keeper %s must be an array of strings" label)
;;

let string_list_field_opt_result ?label ~field_name (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member field_name json with
  | `Null -> Ok []
  | _ -> string_list_field_result ?label ~field_name json
;;

let parse_tool_preset_projection (json : Yojson.Safe.t) =
  let preset_member = Yojson.Safe.Util.member "tool_preset" json in
  match preset_member with
  | `String raw ->
    (match tool_preset_of_string raw with
     | Some preset -> Ok preset
     | None -> Error (Printf.sprintf "invalid keeper tool_preset: %s" raw))
  | `Null -> Error "keeper tool_preset required"
  | _ -> Error "keeper tool_preset must be a string"
;;

let default_tool_access_of_meta_json () =
  migrate_legacy_restricted_tools legacy_session_min_tool_names
;;

let legacy_tool_access_projection_of_meta_json (json : Yojson.Safe.t) =
  let custom_present = json_member_present "tool_custom_allowlist" json in
  let preset_present = json_member_present "tool_preset" json in
  let also_allow_present = json_member_present "tool_also_allow" json in
  let legacy_allowlist_present = json_member_present "tool_allowlist" json in
  if custom_present
  then (
    match string_list_field_result ~field_name:"tool_custom_allowlist" json with
    | Ok tools -> Ok (normalize_tool_access (Custom tools))
    | Error msg -> Error msg)
  else if preset_present || also_allow_present
  then (
    match parse_tool_preset_projection json with
    | Error msg -> Error msg
    | Ok preset ->
      (match string_list_field_opt_result ~field_name:"tool_also_allow" json with
       | Ok also_allow -> Ok (normalize_tool_access (Preset { preset; also_allow }))
       | Error msg -> Error msg))
  else if legacy_allowlist_present
  then (
    match string_list_field_result ~field_name:"tool_allowlist" json with
    | Ok names -> Ok (migrate_legacy_restricted_tools names)
    | Error msg -> Error msg)
  else Ok (default_tool_access_of_meta_json ())
;;

let legacy_tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Null -> legacy_tool_access_projection_of_meta_json json
  | `Assoc _ as access_json ->
    let kind =
      Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
    in
    (match kind with
     | Some "unrestricted" ->
       Ok (Preset { preset = Full; also_allow = [] } |> normalize_tool_access)
     | Some "restricted" ->
       (match
          string_list_field_opt_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools -> Ok (migrate_legacy_restricted_tools tools)
        | Error msg -> Error msg)
     | Some "preset" ->
       let preset_raw =
         Yojson.Safe.Util.member "preset" access_json |> Yojson.Safe.Util.to_string_option
       in
       (match preset_raw with
        | None -> Error "keeper tool_access.preset required"
        | Some raw ->
          (match tool_preset_of_string raw with
           | None -> Error (Printf.sprintf "invalid keeper tool_access.preset: %s" raw)
           | Some preset ->
             (match
                string_list_field_opt_result
                  ~field_name:"also_allow"
                  ~label:"tool_access.also_allow"
                  access_json
              with
              | Ok also_allow ->
                Ok (normalize_tool_access (Preset { preset; also_allow }))
              | Error msg -> Error msg)))
     | Some "custom" ->
       (match
          string_list_field_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools -> Ok (normalize_tool_access (Custom tools))
        | Error msg -> Error msg)
     | Some other -> Error (Printf.sprintf "invalid keeper tool_access.kind: %s" other)
     | None -> Error "keeper tool_access.kind required")
  | _ -> Error "keeper tool_access must be an object"
;;

let tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Null -> Ok (default_tool_access_of_meta_json ())
  | `Assoc _ as access_json ->
    let kind =
      Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
    in
    (match kind with
     | Some "preset" ->
       let preset_raw =
         Yojson.Safe.Util.member "preset" access_json |> Yojson.Safe.Util.to_string_option
       in
       (match preset_raw with
        | None -> Error "keeper tool_access.preset required"
        | Some raw ->
          (match tool_preset_of_string raw with
           | None -> Error (Printf.sprintf "invalid keeper tool_access.preset: %s" raw)
           | Some preset ->
             (match
                string_list_field_opt_result
                  ~field_name:"also_allow"
                  ~label:"tool_access.also_allow"
                  access_json
              with
              | Ok also_allow ->
                Ok (normalize_tool_access (Preset { preset; also_allow }))
              | Error msg -> Error msg)))
     | Some "custom" ->
       (match
          string_list_field_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools -> Ok (normalize_tool_access (Custom tools))
        | Error msg -> Error msg)
     | Some other -> Error (Printf.sprintf "invalid keeper tool_access.kind: %s" other)
     | None -> Error "keeper tool_access.kind required")
  | _ -> Error "keeper tool_access must be an object"
;;

(* -- Updater helpers for nested record updates -- *)

let map_runtime (f : agent_runtime_state -> agent_runtime_state) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = f m.runtime }
;;

let map_usage (f : usage_metrics -> usage_metrics) (m : keeper_meta) : keeper_meta =
  { m with runtime = { m.runtime with usage = f m.runtime.usage } }
;;

let zero_usage : usage_metrics =
  { total_turns = 0; total_input_tokens = 0; total_output_tokens = 0
  ; total_tokens = 0; total_cost_usd = 0.0; last_turn_ts = 0.0
  ; last_model_used = ""; last_input_tokens = 0; last_output_tokens = 0
  ; last_total_tokens = 0; last_latency_ms = 0 }

let reset_runtime_state (m : keeper_meta) : keeper_meta =
  map_usage (fun _ -> zero_usage) m

let map_compaction_rt (f : compaction_runtime -> compaction_runtime) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = { m.runtime with compaction_rt = f m.runtime.compaction_rt } }
;;

let map_proactive_rt (f : proactive_runtime -> proactive_runtime) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = { m.runtime with proactive_rt = f m.runtime.proactive_rt } }
;;

let map_scheduled_autonomous_rt =
  map_proactive_rt
;;

let now_iso () = Types.now_iso ()
let keeper_legacy_model_arg_names = [ "models"; "allowed_models"; "active_model" ]

let runtime_meta_write_sync_hook : (Room.config -> keeper_meta -> unit) ref =
  ref (fun _ _ -> ())
;;

let register_runtime_meta_write_sync f = runtime_meta_write_sync_hook := f

let reject_legacy_model_args ~tool_name (args : Yojson.Safe.t) =
  let present =
    keeper_legacy_model_arg_names
    |> List.filter (fun key ->
      match Yojson.Safe.Util.member key args with
      | `Null -> false
      | _ -> true)
  in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "legacy keeper model args removed for %s: %s. Keepers now use cascade_name and \
          last_model_used only."
         tool_name
         (String.concat ", " fields))
;;

let drop_assoc_keys (keys : string list) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | _ -> json
;;

let reject_removed_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys removed_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error (Printf.sprintf "removed keeper meta fields: %s" (String.concat ", " fields))
;;

let legacy_keeper_meta_tool_policy_key_names =
  [ "tool_preset"; "tool_also_allow"; "tool_custom_allowlist"; "tool_allowlist" ]
;;

let legacy_keeper_meta_key_names =
  "allowed_providers" :: legacy_keeper_meta_tool_policy_key_names
;;

let reject_legacy_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys legacy_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "legacy keeper meta fields require scrub via read_meta_file_path: %s"
         (String.concat ", " fields))
;;

let legacy_tool_access_kind_needs_scrub (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Assoc _ as access_json ->
    (match
       Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
     with
     | Some "restricted" | Some "unrestricted" -> true
     | _ -> false)
  | _ -> false
;;

let scrub_legacy_tool_policy_meta_json (json : Yojson.Safe.t) : Yojson.Safe.t * string list =
  let present = present_json_keys legacy_keeper_meta_key_names json in
  let missing_tool_access = not (json_member_present "tool_access" json) in
  let legacy_tool_access_kind = legacy_tool_access_kind_needs_scrub json in
  let needs_tool_access_rewrite =
    present <> [] || missing_tool_access || legacy_tool_access_kind
  in
  if not needs_tool_access_rewrite
  then json, []
  else
    match legacy_tool_access_of_meta_json json with
    | Error _ ->
      let dropped =
        present |> List.filter (fun key -> String.equal key "allowed_providers")
      in
      if dropped = []
      then json, []
      else
        (drop_assoc_keys dropped json, dropped)
    | Ok tool_access ->
      let rewrite_reasons =
        (if missing_tool_access then [ "tool_access(defaulted)" ] else [])
        @ (if legacy_tool_access_kind then [ "tool_access(legacy-kind)" ] else [])
        @ present
      in
      let base = drop_assoc_keys legacy_keeper_meta_key_names json in
      let scrubbed =
        match base with
        | `Assoc fields ->
          `Assoc
            (("tool_access", tool_access_to_json tool_access)
             :: List.remove_assoc "tool_access" fields)
        | _ -> base
      in
      scrubbed, rewrite_reasons
;;

let scrub_persisted_keeper_meta_json ~path (json : Yojson.Safe.t) : Yojson.Safe.t * bool =
  let json, legacy_tool_policy_rewrites = scrub_legacy_tool_policy_meta_json json in
  match json with
  | `Assoc fields ->
    let removed_present =
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key removed_keeper_meta_key_names then Some key else None)
    in
    if removed_present = [] && legacy_tool_policy_rewrites = []
    then json, false
    else (
      let migrate_legacy_disabled_keepalive =
        (match List.assoc_opt "presence_keepalive" fields with
         | Some (`Bool false) -> true
         | _ -> false)
        && not (List.mem_assoc "paused" fields)
      in
      let scrubbed =
        let base = drop_assoc_keys removed_keeper_meta_key_names json in
        match base with
        | `Assoc base_fields when migrate_legacy_disabled_keepalive ->
          `Assoc (("paused", `Bool true) :: List.remove_assoc "paused" base_fields)
        | _ -> base
      in
      let content = Yojson.Safe.pretty_to_string scrubbed in
      (try
         Fs_compat.save_file path content;
         Log.Keeper.info
           "scrubbed legacy keeper meta fields for %s: %s%s"
           path
           (String.concat ", " (legacy_tool_policy_rewrites @ removed_present))
           (if migrate_legacy_disabled_keepalive
            then " (migrated presence_keepalive=false to paused=true)"
            else "")
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn
           "failed to scrub removed keeper meta fields for %s: %s"
           path
           (Printexc.to_string exn));
      scrubbed, true)
  | _ -> json, false
;;

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  let rt = m.runtime in
  `Assoc
    [ "name", `String m.name
    ; "agent_name", `String m.agent_name
    ; "trace_id", `String (Keeper_id.Trace_id.to_string rt.trace_id)
    ; "trace_history", `List (List.map (fun s -> `String s) rt.trace_history)
    ; "goal", `String m.goal
    ; "short_goal", `String m.short_goal
    ; "mid_goal", `String m.mid_goal
    ; "long_goal", `String m.long_goal
    
    ; "social_model", `String m.social_model
    ; "cascade_name", `String m.cascade_name
    (* "models" intentionally omitted from serialization.  The field
       is in removed_keeper_meta_key_names (via removed_keeper_input_key_names)
       and scrub_persisted_keeper_meta_json strips it on every load.
       Re-emitting it here creates a scrub → write → re-scrub loop that
       fires ~20 INFO log lines per keeper per session.  Models are
       resolved at runtime from cascade config, not from persisted meta. *)
    ; "will", `String m.will
    ; "needs", `String m.needs
    ; "desires", `String m.desires
    ; "instructions", `String m.instructions
    ; "policy_voice_enabled", `Bool m.policy_voice_enabled
    ; "execution_scope", `String (Keeper_execution_scope.to_string m.execution_scope)
    ; "allowed_paths", `List (List.map (fun s -> `String s) m.allowed_paths)
    ; "tool_access", tool_access_to_json m.tool_access
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
    ; "last_need", `String rt.last_need
    ; "paused", `Bool m.paused
    ; "autoboot_enabled", `Bool m.autoboot_enabled
    ; "current_task_id", Json_util.string_opt_to_json (Option.map Keeper_id.Task_id.to_string m.current_task_id)
    ; "max_context_override", Json_util.int_opt_to_json m.max_context_override
    ; "work_discovery_enabled", Json_util.bool_opt_to_json m.work_discovery_enabled
    ; "work_discovery_sources"
      , (match m.work_discovery_sources with
         | Some xs -> `List (List.map (fun s -> `String s) xs)
         | None -> `Null)
    ; "work_discovery_interval_sec", Json_util.int_opt_to_json m.work_discovery_interval_sec
    ; "work_discovery_guidance", Json_util.string_opt_to_json m.work_discovery_guidance
    ; "telemetry_feedback_enabled", Json_util.bool_opt_to_json m.telemetry_feedback_enabled
    ; "telemetry_feedback_window_hours", Json_util.int_opt_to_json m.telemetry_feedback_window_hours
    ]
;;

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
  ; pk_models : string list
  ; pk_will : string
  ; pk_needs : string
  ; pk_desires : string
  ; pk_instructions : string
  }

type parsed_keeper_policy =
  { pp_policy_voice_enabled : bool
  ; pp_execution_scope : Keeper_execution_scope.t
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
  }

type parsed_keeper_state =
  { ps_created_at_raw : string
  ; ps_updated_at_raw : string
  ; ps_continuity_summary : string
  ; ps_active_goal_ids : string list
  ; ps_paused : bool
  ; ps_autoboot_enabled : bool
  ; ps_current_task_id : Keeper_id.Task_id.t option
  ; ps_max_context_override : int option
  ; ps_runtime : agent_runtime_state
  }

let parse_keeper_identity (json : Yojson.Safe.t)
    : (parsed_keeper_identity, string) result =
  let pk_name = Safe_ops.json_string ~default:"" "name" json in
  let pk_agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
  let pk_trace_id_raw = Safe_ops.json_string ~default:"" "trace_id" json in
  match
    if String.trim pk_trace_id_raw = "" then
      Error "missing trace_id in persisted keeper identity"
    else
      match Keeper_id.Trace_id.of_string pk_trace_id_raw with
      | Ok x -> Ok x
      | Error err ->
        Error
          ("invalid trace_id in persisted keeper identity: " ^ err)
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
    Safe_ops.json_string ~default:default_social_model "social_model" json
  in
  let pk_will =
    Safe_ops.json_string ~default:default_keeper_will "will" json
    |> normalize_self_model_text
  in
  let pk_needs =
    Safe_ops.json_string ~default:default_keeper_needs "needs" json
    |> normalize_self_model_text
  in
  let pk_desires =
    Safe_ops.json_string ~default:default_keeper_desires "desires" json
    |> normalize_self_model_text
  in
  let pk_instructions = Safe_ops.json_string ~default:"" "instructions" json in
  let pk_cascade_name =
    Safe_ops.json_string ~default:Keeper_config.default_cascade_name "cascade_name" json
    |> Keeper_cascade_profile.canonicalize
  in
  let pk_models =
    match json |> Yojson.Safe.Util.member "models" with
    | `List items ->
      List.filter_map
        (function `String s -> Some (String.trim s) | _ -> None)
        items
    | _ -> []
  in
  Ok { pk_name
  ; pk_agent_name
  ; pk_trace_id
  ; pk_trace_history
  ; pk_goal
  ; pk_short_goal
  ; pk_mid_goal
  ; pk_long_goal
  ; pk_social_model
  ; pk_cascade_name
  ; pk_models
  ; pk_will
  ; pk_needs
  ; pk_desires
  ; pk_instructions
  }
;;

let parse_keeper_policy (json : Yojson.Safe.t) ~(keeper_name : string)
  : (parsed_keeper_policy, string) result
  =
  let voice_enabled_default = default_voice_enabled_for keeper_name in
  match tool_access_of_meta_json json with
  | Error msg -> Error ("meta parse error: " ^ msg)
  | Ok pp_tool_access ->
    let pp_policy_voice_enabled =
      Safe_ops.json_bool ~default:voice_enabled_default "policy_voice_enabled" json
    in
    let pp_execution_scope =
      Safe_ops.json_string ~default:(Keeper_execution_scope.to_string default_execution_scope) "execution_scope" json
      |> Keeper_execution_scope.of_string_lossy
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
    Ok
      { pp_policy_voice_enabled
      ; pp_execution_scope
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
      }
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
  }
;;

let parse_proactive_runtime (json : Yojson.Safe.t) : proactive_runtime =
  let count_total = Safe_ops.json_int ~default:0 "proactive_count_total" json in
  let last_ts = Safe_ops.json_float ~default:0.0 "last_proactive_ts" json in
  { count_total
  ; last_ts
  ; visible_count_total =
      Safe_ops.json_int
        ~default:0
        "proactive_visible_count_total"
        json
  ; last_visible_ts =
      Safe_ops.json_float
        ~default:0.0
        "last_visible_proactive_ts"
        json
  ; last_outcome =
      Safe_ops.json_string_opt "last_proactive_outcome" json
      |> Option.value ~default:"unknown"
      |> proactive_cycle_outcome_of_string
  ; last_reason = Safe_ops.json_string ~default:"" "last_proactive_reason" json
  ; last_preview = Safe_ops.json_string ~default:"" "last_proactive_preview" json
  ; last_work_discovery_ts =
      Safe_ops.json_float ~default:0.0 "last_work_discovery_ts" json
  ; work_discovery_count =
      Safe_ops.json_int ~default:0 "work_discovery_count" json
  ; consecutive_noop_count =
      Safe_ops.json_int ~default:0 "consecutive_noop_count" json
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
  let consecutive_noop_count = Safe_ops.json_int ~default:0 "consecutive_noop_count" json in
  let last_speech_act = Safe_ops.json_string ~default:"" "last_speech_act" json in
  let last_social_transition_reason =
    Safe_ops.json_string ~default:"" "last_social_transition_reason" json
  in
  let last_active_desire =
    Safe_ops.json_string ~default:"" "last_active_desire" json
  in
  let last_current_intention =
    Safe_ops.json_string ~default:"" "last_current_intention" json
  in
  let last_blocker = Safe_ops.json_string ~default:"" "last_blocker" json in
  let last_need = Safe_ops.json_string ~default:"" "last_need" json in
  let ps_paused = Safe_ops.json_bool ~default:false "paused" json in
  let ps_autoboot_enabled =
    Safe_ops.json_bool ~default:true "autoboot_enabled" json
  in
  let ps_current_task_id = match Safe_ops.json_string_opt "current_task_id" json with None -> None | Some s -> (match Keeper_id.Task_id.of_string s with Ok tid -> Some tid | Error _ -> None) in
  let ps_max_context_override = Safe_ops.json_int_opt "max_context_override" json in
  { ps_created_at_raw
  ; ps_updated_at_raw
  ; ps_continuity_summary
  ; ps_active_goal_ids
  ; ps_paused
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
    | Ok () -> (
      match reject_legacy_keeper_meta_fields json with
      | Error e -> Error e
      | Ok () ->
      (match parse_keeper_identity json with
       | Error _ as e -> e
       | Ok identity ->
      match parse_keeper_policy json ~keeper_name:identity.pk_name with
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
         else if not (validate_name (Keeper_id.Trace_id.to_string identity.pk_trace_id))
         then Error "invalid keeper meta (bad trace_id)"
         else
           Ok
             { name = identity.pk_name
             ; agent_name =
                 (if identity.pk_agent_name = ""
                  then keeper_agent_name identity.pk_name
                  else identity.pk_agent_name)
             ; goal = identity.pk_goal
             ; short_goal = identity.pk_short_goal
             ; mid_goal = identity.pk_mid_goal
             ; long_goal = identity.pk_long_goal
             ; social_model = identity.pk_social_model
             ; cascade_name = identity.pk_cascade_name
             ; models = identity.pk_models
             ; will = identity.pk_will
             ; needs = identity.pk_needs
             ; desires = identity.pk_desires
             ; instructions = identity.pk_instructions
             ; policy_voice_enabled = policy.pp_policy_voice_enabled
             ; execution_scope = policy.pp_execution_scope
             ; allowed_paths = policy.pp_allowed_paths
             ; tool_access = policy.pp_tool_access
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
             ; autoboot_enabled = state.ps_autoboot_enabled
             ; current_task_id = state.ps_current_task_id
             ; max_context_override = state.ps_max_context_override
             ; work_discovery_enabled = Safe_ops.json_bool_opt "work_discovery_enabled" json
             ; work_discovery_sources =
                 (match json with
                  | `Assoc fields ->
                    (match List.assoc_opt "work_discovery_sources" fields with
                     | Some (`List items) ->
                       Some (List.filter_map (function
                         | `String s -> Some s | _ -> None) items)
                     | _ -> None)
                  | _ -> None)
             ; work_discovery_interval_sec = Safe_ops.json_int_opt "work_discovery_interval_sec" json
             ; work_discovery_guidance = Safe_ops.json_string_opt "work_discovery_guidance" json
             ; telemetry_feedback_enabled = Safe_ops.json_bool_opt "telemetry_feedback_enabled" json
             ; telemetry_feedback_window_hours = Safe_ops.json_int_opt "telemetry_feedback_window_hours" json
             ; runtime = state.ps_runtime
             })
      )
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "meta parse error: %s" (Printexc.to_string exn))
;;

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
  ; "execution_scope"
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

let read_meta_file_path path : (keeper_meta option, string) result =
  if not (Fs_compat.file_exists path)
  then Ok None
  else (
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
      let json, _scrubbed = scrub_persisted_keeper_meta_json ~path json in
      warn_unknown_keeper_meta_keys ~path json;
      (match meta_of_json json with
       | Ok meta -> Ok (Some meta)
       | Error e ->
         Log.Keeper.warn "keeper meta parse failed for %s: %s" path e;
         Error e))
;;

(** Sidecar stem suffixes (without the trailing .json).
    A file like [sangsu.dataset.json] has stem [sangsu.dataset]; stripping
    [.json] and checking [String.ends_with ~suffix] on this stem filters
    sidecars while allowing keeper names that contain dots (e.g.
    [dot.name.json]). When adding a new sidecar kind, add its dot-prefixed
    suffix here. *)
let keeper_sidecar_stem_suffixes =
  [ ".dataset" ]

let is_keeper_meta_file f =
  if not (Filename.check_suffix f ".json") then false
  else
    let stem = Filename.chop_suffix f ".json" in
    stem <> ""
    && not
         (List.exists
            (fun suf ->
              String.length stem > String.length suf
              && String.ends_with ~suffix:suf stem)
            keeper_sidecar_stem_suffixes)
let persisted_keeper_names config =
  let dir = keeper_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error e ->
    Log.Keeper.warn "persisted_keeper_names: failed to list directory %s: %s" dir e;
    []
  | Ok files ->
    files
    |> List.filter is_keeper_meta_file
    |> List.map Filename.remove_extension
    |> List.filter validate_name
    |> List.sort String.compare
;;

let configured_keeper_names _config =
  Config_dir_resolver.log_warnings ~context:"KeeperTypes" ();
  Keeper_types_profile.discover_keepers_toml (Config_dir_resolver.keepers_dir ())
  |> List.map fst
  |> dedupe_keep_order
;;

let keeper_names config =
  (* Discovery uses persisted JSON (.masc/keepers/*.json) as primary source.
     JSON files are scoped to the server's base_path, so test isolation works.
     Overlay keepers (from .masc/config/keepers/*.toml) are materialized to
     JSON at boot by load_or_materialize_boot_meta, so they appear here too.
     Sidecar files (.dataset) are filtered by is_keeper_meta_file. *)
  persisted_keeper_names config
;;

let keepalive_keeper_names config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
    match read_meta_file_path (keeper_meta_path config name) with
    | Ok (Some meta) when not meta.paused && meta.autoboot_enabled -> Some meta.name
    | Ok None -> Some name
    | _ -> None)
;;

(** Names of keepers that should be running across sessions.
    A keeper is "persistent" when its on-disk meta has autoboot enabled
    and is not currently paused — i.e. the operator expects the runtime
    to keep it alive after restart.

    Mirrors [keepalive_keeper_names] for readers that care about
    durability rather than the keepalive fiber. *)
let persistent_agent_names config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
    match read_meta_file_path (keeper_meta_path config name) with
    | Ok (Some meta) when not meta.paused && meta.autoboot_enabled -> Some meta.name
    | _ -> None)

let fresher_meta config (meta : keeper_meta) : keeper_meta =
  match read_meta_file_path (keeper_meta_path config meta.name) with
  | Ok (Some existing) ->
    let existing_ts =
      Resilience.Time.parse_iso8601_opt existing.updated_at |> Option.value ~default:0.0
    in
    let incoming_ts =
      Resilience.Time.parse_iso8601_opt meta.updated_at |> Option.value ~default:0.0
    in
    if existing_ts > incoming_ts then existing else meta
  | Ok None | Error _ -> meta
;;

let write_meta ?(force = false) config (m : keeper_meta) : (unit, string) result =
  let persisted = if force then m else fresher_meta config m in
  let path = keeper_meta_path config persisted.name in
  let json = meta_to_json persisted in
  try
    Keeper_fs.save_json_atomic path json;
    !runtime_meta_write_sync_hook config persisted;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error (Printf.sprintf "failed to write meta %s: %s" path (Printexc.to_string exn))
;;

let keeper_name_from_agent_name agent_name =
  let prefix = "keeper-" and suffix = "-agent" in
  let plen = String.length prefix and slen = String.length suffix in
  let alen = String.length agent_name in
  if alen > plen + slen
     && String.sub agent_name 0 plen = prefix
     && String.sub agent_name (alen - slen) slen = suffix
  then
    let keeper_name = String.sub agent_name plen (alen - plen - slen) in
    if validate_name keeper_name then Some keeper_name else None
  else
    None
;;

let read_meta_resolved config name : ((string * keeper_meta) option, string) result =
  let requested_name = String.trim name in
  let read_candidate candidate =
    read_meta_file_path (keeper_meta_path config candidate)
    |> Result.map (Option.map (fun meta -> (candidate, meta)))
  in
  if requested_name = "" then
    Ok None
  else
    match read_candidate requested_name with
    | Ok None -> (
        match keeper_name_from_agent_name requested_name with
        | Some alias_name when not (String.equal alias_name requested_name) ->
            read_candidate alias_name
        | _ -> Ok None)
    | Ok (Some _) as ok -> ok
    | Error _ as err -> err
;;

let read_meta config name : (keeper_meta option, string) result =
  let requested_name = String.trim name in
  let path = keeper_meta_path config requested_name in
  if keeper_debug
  then
    Log.Keeper.debug
      "read_meta name=%s path=%s exists=%b"
      requested_name
      path
      (Fs_compat.file_exists path);
  match read_meta_resolved config requested_name with
  | Ok (Some (_resolved_name, meta)) -> Ok (Some meta)
  | Ok None -> Ok None
  | Error _ as err -> err
;;

(** Read keeper meta only if the file's mtime has changed since [last_mtime].
    Returns [Some (meta, new_mtime)] when the file changed, [None] when
    unchanged.  Avoids parsing JSON on every heartbeat cycle when no
    operator has modified the meta file. *)
let read_meta_if_changed config name ~(last_mtime : float)
  : (keeper_meta * float) option =
  let requested_name = String.trim name in
  let read_candidate candidate =
    let path = keeper_meta_path config candidate in
    if not (Fs_compat.file_exists path) then None
    else
      match Fs_compat.file_mtime path with
      | Some mtime when mtime > last_mtime ->
          (match read_meta_file_path path with
          | Ok (Some meta) -> Some (meta, mtime)
          | _ -> None)
      | _ -> None
  in
  match read_candidate requested_name with
  | Some _ as changed -> changed
  | None -> (
      match keeper_name_from_agent_name requested_name with
      | Some alias_name when not (String.equal alias_name requested_name) ->
          read_candidate alias_name
      | _ -> None)
;;

(* Model selection, path utilities, and JSONL helpers
   extracted to Keeper_types_support *)
include Keeper_types_support

(** Fiber-level health for keeper supervisor monitoring.
    Defined here (not in Keeper_supervisor) to avoid circular
    dependencies between keeper_exec_status and the keeper supervisor. *)
type fiber_health =
  | Fiber_alive (** Fiber running, promise unresolved *)
  | Fiber_zombie (** Registry entry exists but fiber terminated *)
  | Fiber_dead (** Restart budget exhausted, manual recovery needed *)
  | Fiber_unknown (** Not in supervised registry *)

(** Keeper-level health state — derived from agent status, keepalive
    fiber, and supervisor monitoring. Serialized to string at JSON
    boundaries only. Defined here (not in Keeper_exec_status) so
    operator_control_snapshot can parse JSON into the same type. *)
type keeper_health =
  | KH_healthy  (** Keepalive alive, recent turns, no quiet_reason *)
  | KH_idle     (** Keepalive alive but no recent activity *)
  | KH_offline  (** Agent not present or status=offline/inactive *)
  | KH_stale    (** Last seen too long ago or zombie flag from agent *)
  | KH_degraded (** graphql_error or model_error quiet_reason *)
  | KH_zombie   (** Fiber terminated but registry entry exists *)
  | KH_dead     (** Restart budget exhausted *)

(** Keeper continuity state — derived from health + keepalive status. *)
type keeper_continuity =
  | Continuity_healthy    (** Runtime aligned with durable state *)
  | Continuity_recovering (** Reconciling back into live presence *)
  | Continuity_not_running (** Keepalive fiber not running *)

(** Per-tool usage entry for keeper tool tracking.
    Defined here so Keeper_registry can embed it without depending
    on Keeper_tools_oas (avoids module init order issues). *)
type tool_call_entry =
  { count : int
  ; successes : int
  ; failures : int
  ; last_used_at : float
  }

(* ================================================================ *)
(* Working Context Types (moved from Keeper_working_context)         *)
(* ================================================================ *)

type working_context =
  { system_prompt : string
  ; messages : Agent_sdk.Types.message list
  ; max_tokens : int
  ; context : Agent_sdk.Context.t
  }

type checkpoint =
  { checkpoint_id : string
  ; timestamp : float
  ; generation : int
  ; message_count : int
  ; token_count : int
  ; serialized : string
  }

type session_context =
  { session_id : string
  ; session_dir : string
  ; mutable checkpoints : checkpoint list
  }
