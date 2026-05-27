(** Keeper status bridge helpers. *)

open Keeper_types

let string_list_to_json = Json_util.json_string_list

let drift_surface_json ~unknown_toml_keys =
  `Assoc
    [ "unknown_toml_keys", string_list_to_json unknown_toml_keys
    ; "unknown_toml_keys_count", `Int (List.length unknown_toml_keys)
    ]
;;

let auto_execution_session_surface_json () =
  `Assoc [ "status", `String "removed"; "enabled", `Bool false ]
;;

let coordination_surface_json (meta : keeper_meta) =
  `Assoc
    [ "mention_targets", string_list_to_json meta.mention_targets
    ; "joined_room_ids", string_list_to_json meta.joined_room_ids
    ]
;;

let effective_declarative_cascade_name
      (defaults : keeper_profile_defaults)
      (meta : keeper_meta)
  =
  match defaults.cascade_name, defaults.manifest_path with
  | Some cascade_name, _ ->
    Keeper_cascade_profile.normalize_keeper_runtime_declared_name cascade_name
  | None, Some _ -> (Keeper_config.default_cascade_name ())
  | None, None ->
    Keeper_cascade_profile.normalize_keeper_runtime_declared_name
      (cascade_name_of_meta meta)
;;

type override_field_detail =
  Keeper_status_bridge_override.override_field_detail =
  { field : string
  ; default_value : Yojson.Safe.t
  ; live_value : Yojson.Safe.t
  }

let override_field = Keeper_status_bridge_override.override_field
let maybe_string_override = Keeper_status_bridge_override.maybe_string_override
let maybe_bool_override = Keeper_status_bridge_override.maybe_bool_override
let maybe_string_list_override =
  Keeper_status_bridge_override.maybe_string_list_override
let nonempty_string_list_override =
  Keeper_status_bridge_override.nonempty_string_list_override
let maybe_string_option_override =
  Keeper_status_bridge_override.maybe_string_option_override

let live_override_details (meta : keeper_meta) (defaults : keeper_profile_defaults)
  : override_field_detail list
  =
  let effective_cascade_name = effective_declarative_cascade_name defaults meta in
  []
  |> maybe_string_override
       "prompt.goal"
       ~normalize:normalize_goal_horizon_text
       defaults.goal
       meta.goal
  |> maybe_string_override "prompt.short_goal" defaults.short_goal meta.short_goal
  |> maybe_string_override "prompt.mid_goal" defaults.mid_goal meta.mid_goal
  |> maybe_string_override "prompt.long_goal" defaults.long_goal meta.long_goal
  |> maybe_string_override "prompt.will" defaults.will meta.will
  |> maybe_string_override "prompt.needs" defaults.needs meta.needs
  |> maybe_string_override "prompt.desires" defaults.desires meta.desires
  |> maybe_string_override "prompt.instructions" defaults.instructions meta.instructions
  |> nonempty_string_list_override
       "coordination.mention_targets"
       defaults.mention_targets
       meta.mention_targets
  |> maybe_string_list_override
       "tools.tool_denylist"
       defaults.tool_denylist
       meta.tool_denylist
  |> (fun acc ->
  let cascade_name = cascade_name_of_meta meta in
  if effective_cascade_name <> cascade_name
  then
    override_field
      "model.cascade_name"
      ~default_value:(`String effective_cascade_name)
      ~live_value:(`String cascade_name)
    :: acc
  else acc)
  |> maybe_bool_override
       "proactive.enabled"
       defaults.proactive_enabled
       meta.proactive.enabled
  |> List.rev
;;

let live_override_fields (meta : keeper_meta) (defaults : keeper_profile_defaults)
  : string list
  =
  live_override_details meta defaults |> List.map (fun detail -> detail.field)
;;

let runtime_registry_entry (config : Coord_utils.config) name =
  Keeper_registry.get ~base_path:config.base_path name
;;

let runtime_keepalive_running (config : Coord_utils.config) (meta : keeper_meta) =
  Keeper_registry.is_running ~base_path:config.base_path meta.name
;;

let runtime_keepalive_started_at (config : Coord_utils.config) (meta : keeper_meta) =
  Keeper_registry.started_at ~base_path:config.base_path meta.name
;;

(* ── Structured blocker classification ──────────────────────── *)
(* Types blocker_class, cascade_exhaustion_reason, blocker_class_to_string,
   cascade_exhaustion_summary, blocker_class_continue_gate
   are defined in Keeper_types (keeper_types.ml). *)


include Keeper_status_bridge_blocker


let has_any_ci text needles = List.exists (String_util.contains_substring_ci text) needles

let first_nonempty_line label values =
  values
  |> List.map String.trim
  |> List.find_map (fun value ->
    if String.equal value "" then None else Some (Printf.sprintf "%s: %s" label value))
;;

let progress_snapshot_narrative_lines
      (snapshot : Keeper_memory_policy.keeper_state_snapshot)
  =
  [ (match snapshot.progress with
     | Some progress -> Some ("Progress: " ^ String.trim progress)
     | None -> None)
  ; (match snapshot.done_summary with
     | Some done_summary -> Some ("Done: " ^ String.trim done_summary)
     | None -> None)
  ; (match snapshot.next_summary with
     | Some next_summary -> Some ("Next plan: " ^ String.trim next_summary)
     | None -> None)
  ; first_nonempty_line "Next" snapshot.next_items
  ; first_nonempty_line "Decisions" snapshot.decisions
  ; first_nonempty_line "OpenQuestions" snapshot.open_questions
  ; first_nonempty_line "Constraints" snapshot.constraints
  ]
  |> List.filter_map (function
    | Some line when not (String.equal (String.trim line) "") -> Some line
    | _ -> None)
;;

let narrative_summary line =
  String_util.utf8_safe ~max_bytes:220 ~suffix:"..." line |> String_util.to_string
;;

let runtime_blocker_surface_of_progress_snapshot
      (snapshot : Keeper_memory_policy.keeper_state_snapshot)
  =
  let lines = progress_snapshot_narrative_lines snapshot in
  let text = String.concat "\n" lines in
  let line_with needles = List.find_opt (fun line -> has_any_ci line needles) lines in
  let surface blocker_class line =
    Some { blocker_class; summary = narrative_summary line; continue_gate = false }
  in
  if lines = []
  then None
  else (
    match
      line_with
        [ "sandbox egress"
        ; "push egress"
        ; "github.com push"
        ; "github push"
        ; "network egress"
        ; "sandbox"
        ]
    with
    | Some line when has_any_ci line [ "egress"; "push"; "github.com"; "network" ] ->
      surface "awaiting_sandbox_egress" line
    | _ ->
      (match line_with [ "supervisor"; "supervisor가" ] with
       | Some line when has_any_ci line [ "pause"; "paused"; "unpause"; "의도" ] ->
         surface "supervisor_paused" line
       | _ ->
         (match
            line_with
              [ "push gate"
              ; "operator"
              ; "human"
              ; "approval"
              ; "approve"
              ; "decision tree"
              ; "4-gate"
              ; "4 gate"
              ; "unblock"
              ; "manual"
              ]
          with
          | Some line
            when has_any_ci
                   line
                   [ "waiting"
                   ; "await"
                   ; "blocked"
                   ; "respond"
                   ; "resolved"
                   ; "gate"
                   ; "decision"
                   ; "approval"
                   ; "approve"
                   ; "unblock"
                   ; "manual"
                   ] -> surface "awaiting_operator" line
          | _ ->
            if
              Keeper_synthetic_marker.contains_marker text
              && has_any_ci
                   text
                   [ "no visible output"
                   ; "last output"
                   ; "belief_summary"
                   ; "social_model"
                   ; "실제 막힘"
                   ]
            then
              (* The outer [if lines = [] then None] guard (line 168)
                 already returns early on an empty narrative; the
                 [[]] arm below is unreachable here but typed for
                 exhaustiveness so a future refactor that drops the
                 outer guard does not silently fall through to a
                 Sys_error from [List.hd]. *)
              let first_line =
                match lines with
                | [] -> ""
                | h :: _ -> h
              in
              surface
                "synthetic_stall"
                (line_with [ Keeper_synthetic_marker.marker_prefix ]
                 |> Option.value ~default:first_line)
            else (
              match
                line_with
                  [ "watching"
                  ; "monitor"
                  ; "no action"
                  ; "no next action"
                  ; "자체 action 부재"
                  ; "감시"
                  ]
              with
              | Some line -> surface "self_imposed_idle" line
              | None -> None))))
;;

let runtime_blocker_surface_of_progress_narrative config (meta : keeper_meta) =
  let from_continuity_summary =
    match
      Keeper_memory_policy.progress_snapshot_cache_of_text meta.continuity_summary
    with
    | Some cache -> runtime_blocker_surface_of_progress_snapshot cache.snapshot
    | None -> None
  in
  match from_continuity_summary with
  | Some _ as blocker -> blocker
  | None ->
    (match Keeper_memory_policy.read_progress_snapshot ~config ~name:meta.name with
     | Some snapshot -> runtime_blocker_surface_of_progress_snapshot snapshot
     | None -> None)
;;

let runtime_blocker_surface_opt (config : Coord_utils.config) (meta : keeper_meta) =
  let derived =
    match meta.runtime.last_blocker with
    | Some info ->
      Some (runtime_blocker_surface_of_typed_class ~summary:info.detail info.klass)
    | None ->
      (match runtime_registry_entry config meta.name with
       | Some entry ->
         (match entry.last_failure_reason with
          | Some reason -> runtime_blocker_surface_of_failure_reason reason
          | None -> None)
       | None -> None)
  in
  let derived =
    match derived with
    | Some blocker -> Some blocker
    | None -> runtime_blocker_surface_of_progress_narrative config meta
  in
  derived
;;

let cascade_attempt_outcome_json = function
  | `Success -> `Assoc [ "kind", `String "success"; "detail", `Null ]
  | `Failure detail ->
    `Assoc [ "kind", `String "failure"; "detail", `String detail ]
;;

let cascade_attempt_record_json (attempt : cascade_attempt_record) =
  `Assoc
    [ "provider_id", `String attempt.provider_id
    ; "http_status", Json_util.int_opt_to_json attempt.http_status
    ; "outcome", cascade_attempt_outcome_json attempt.outcome
    ; "timestamp_unix", `Float attempt.timestamp
    ]
;;

let last_cascade_attempt_json (meta : keeper_meta) =
  match meta.runtime.last_cascade_attempt with
  | None -> `Null
  | Some attempt -> cascade_attempt_record_json attempt
;;

let runtime_blocker_facts_json (meta : keeper_meta) =
  `Assoc
    [ "source", `String "keeper_runtime.last_cascade_attempt"
    ; "cascade_name", `String (cascade_name_of_meta meta)
    ; "last_cascade_attempt", last_cascade_attempt_json meta
    ]
;;

let runtime_blocker_fields_json (config : Coord_utils.config) (meta : keeper_meta) =
  match runtime_blocker_surface_opt config meta with
  | Some blocker ->
    [ "runtime_blocker_class", `String blocker.blocker_class
    ; "runtime_blocker_summary", `String blocker.summary
    ; "runtime_blocker_continue_gate", `Bool blocker.continue_gate
    ; "runtime_blocker_facts", runtime_blocker_facts_json meta
    ]
  | None ->
    [ "runtime_blocker_class", `Null
    ; "runtime_blocker_summary", `Null
    ; "runtime_blocker_continue_gate", `Bool false
    ; "runtime_blocker_facts", `Null
    ]
;;

let runtime_state_fields_json (config : Coord_utils.config) (meta : keeper_meta) =
  let runtime_blocker = runtime_blocker_surface_opt config meta in
  let pause_state = if meta.paused then "paused" else "active" in
  let blocker_state =
    match runtime_blocker with
    | Some blocker when blocker.continue_gate -> "continue_gate"
    | Some _ -> "blocked"
    | None -> "clear"
  in
  [ "pause_state", `String pause_state; "runtime_blocker_state", `String blocker_state ]
;;

let attention_fields_json (config : Coord_utils.config) (meta : keeper_meta) =
  let pending_approval_count =
    Keeper_approval_queue.pending_count_for_keeper ~keeper_name:meta.name
  in
  let runtime_blocker = runtime_blocker_surface_opt config meta in
  let social_model_recognized =
    Keeper_social_model.is_known_social_model meta.social_model
  in
  let needs_attention, attention_reason, next_human_action =
    if pending_approval_count > 0
    then true, Some "approval_pending", Some "resolve_approval"
    else (
      match runtime_blocker with
      | Some blocker when blocker.continue_gate ->
        true, Some "continue_gate_required", Some "approve_or_reject_continue"
      | Some _ when meta.paused ->
        true, Some "paused", Some "inspect_blocker_before_resume"
      | Some blocker when is_cascade_exhausted_blocker_class blocker.blocker_class ->
        true, Some "cascade_attempts_exhausted", Some "inspect_cascade_attempts"
      | Some blocker when is_no_tool_capable_provider_blocker_class blocker.blocker_class ->
        true, Some "provider_tool_capability_missing", Some "inspect_provider_tool_lane"
      | Some blocker when is_completion_contract_blocker_class blocker.blocker_class ->
        true, Some "completion_contract_violation", Some "inspect_completion_contract"
      | Some blocker when is_provider_runtime_blocker_class blocker.blocker_class ->
        true, Some "provider_runtime_error", Some "inspect_provider_runtime_cause"
      | Some blocker when is_stale_watchdog_blocker_class blocker.blocker_class ->
        true, Some "watchdog_stale_turn", Some "inspect_watchdog_root_cause"
      | Some blocker when is_fiber_unresolved_blocker_class blocker.blocker_class ->
        true, Some "fiber_unresolved", Some "inspect_turn_finalization"
      | Some _ -> true, Some "runtime_blocked", Some "inspect_runtime_blocker"
      | None when meta.paused -> true, Some "paused", Some "resume_or_review"
      | None when not social_model_recognized ->
        true, Some "social_model_fallback", Some "review_social_model"
      | None -> false, None, None)
  in
  [ "needs_attention", `Bool needs_attention
  ; "attention_reason", Json_util.string_opt_to_json attention_reason
  ; "next_human_action", Json_util.string_opt_to_json next_human_action
  ]
;;

let json_string_opt_member json key =
  match Yojson.Safe.Util.member key json with
  | `String value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

let assoc_upsert fields key value =
  let rec loop acc = function
    | [] -> List.rev ((key, value) :: acc)
    | (existing_key, _) :: rest when String.equal existing_key key ->
      List.rev_append acc ((key, value) :: rest)
    | field :: rest -> loop (field :: acc) rest
  in
  loop [] fields
;;

let attention_fields_with_runtime_trust attention_fields runtime_trust =
  let existing_needs_attention =
    match List.assoc_opt "needs_attention" attention_fields with
    | Some (`Bool value) -> value
    | _ -> false
  in
  let trust_needs_attention =
    Safe_ops.json_bool_opt "needs_attention" runtime_trust |> Option.value ~default:false
  in
  if existing_needs_attention || not trust_needs_attention
  then attention_fields
  else (
    let attention_reason =
      match List.assoc_opt "attention_reason" attention_fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ ->
        (match json_string_opt_member runtime_trust "attention_reason" with
         | Some _ as value -> value
         | None -> json_string_opt_member runtime_trust "disposition_reason")
    in
    let next_human_action =
      match List.assoc_opt "next_human_action" attention_fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ ->
        (match json_string_opt_member runtime_trust "next_human_action" with
         | Some _ as value -> value
         | None ->
           (match json_string_opt_member runtime_trust "latest_next_action" with
            | Some _ as value -> value
            | None -> Some "inspect_runtime_trust"))
    in
    let attention_fields = assoc_upsert attention_fields "needs_attention" (`Bool true) in
    let attention_fields =
      assoc_upsert
        attention_fields
        "attention_reason"
        (Json_util.string_opt_to_json attention_reason)
    in
    assoc_upsert
      attention_fields
      "next_human_action"
      (Json_util.string_opt_to_json next_human_action))
;;

let trimmed_string_json value =
  let trimmed = String.trim value in
  if trimmed = "" then `Null else `String trimmed
;;

let social_model_resolution_fields_json (meta : keeper_meta) =
  let resolved = Keeper_social_model.normalize_social_model meta.social_model in
  let recognized = Keeper_social_model.is_known_social_model meta.social_model in
  [ "social_model", `String resolved
  ; "configured_social_model", trimmed_string_json meta.social_model
  ; "social_model_recognized", `Bool recognized
  ; ( "social_model_fallback"
    , match Keeper_social_model.fallback_social_model meta.social_model with
      | Some fallback -> `String fallback
      | None -> `Null )
  ]
;;

let social_runtime_fields_json (meta : keeper_meta) =
  let delivery_surface_view =
    Keeper_social_model.delivery_surface_view_of_meta meta
    |> Option.map Keeper_social_model.delivery_surface_to_string
  in
  let delivery_surface_view_source =
    Keeper_social_model.delivery_surface_view_source_of_meta meta
  in
  social_model_resolution_fields_json meta
  @ [ "active_model_label", `Null
    ; "last_model_used_label", `Null
    ; "last_speech_act", trimmed_string_json meta.runtime.last_speech_act
    ; "delivery_surface_view", Json_util.string_opt_to_json delivery_surface_view
    ; ( "delivery_surface_view_source"
      , Json_util.string_opt_to_json delivery_surface_view_source )
    ; ( "last_social_transition_reason"
      , trimmed_string_json meta.runtime.last_social_transition_reason )
    ; ( "last_blocker"
      , match meta.runtime.last_blocker with
        | Some info -> blocker_info_to_json info
        | None -> `Null )
    ; "last_need", trimmed_string_json meta.runtime.last_need
    ]
;;

let runtime_surface_json config (meta : keeper_meta) =
  let keepalive_running = runtime_keepalive_running config meta in
  let fiber_health =
    match Keeper_registry.fiber_health_of ~base_path:config.base_path meta.name with
    | Fiber_unknown when keepalive_running -> Fiber_alive
    | health -> health
  in
  let phase =
    match runtime_registry_entry config meta.name with
    | Some entry -> Some (Keeper_state_machine.phase_to_string entry.phase)
    | None -> None
  in
  `Assoc
    ([ "paused", `Bool meta.paused
     ; "keepalive_running", `Bool keepalive_running
     ; ( "phase"
       , match phase with
         | Some p -> `String p
         | None -> `Null )
     ; "fiber_health", `String (Keeper_status_runtime.string_of_fiber_health fiber_health)
     ; "last_cascade_attempt", last_cascade_attempt_json meta
     ]
     @ social_runtime_fields_json meta
     @ runtime_state_fields_json config meta
     @ runtime_blocker_fields_json config meta
     @ attention_fields_json config meta)
;;

let existing_path_json ?source path =
  let fields = [ "path", `String path; "exists", `Bool (Fs_compat.file_exists path) ] in
  let fields =
    match source with
    | Some value -> ("source", `String value) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)
;;

let optional_existing_path_json ?source = function
  | Some path -> existing_path_json ?source path
  | None -> `Null
;;

(* RFC-0058 §9 Phase 9.3: on-disk cascade JSON is no longer generated or
   consumed. [cascade_runtime_json_path] / [cascade_runtime_json_editable]
   dropped from the status payload because there is no runtime JSON
   sibling to point at. Source identity is now fully described by the
   TOML path + the single-arm [source_kind]. *)
let cascade_catalog_source_fields (resolution : Config_dir_resolver.resolution) =
  let source =
    Cascade_toml_materializer.source_info ~config_path:resolution.cascade.path
  in
  [ ( "cascade_catalog_source_kind"
    , `String (Cascade_toml_materializer.source_kind_to_string source.kind) )
  ; "cascade_catalog_source_path", `String source.source_path
  ]
;;

let override_field_source_json ~default_source_kind ~default_manifest_path detail =
  let default_missing =
    match detail.default_value with
    | `Null -> true
    | _ -> false
  in
  let default_manifest_exists =
    match default_manifest_path with
    | Some path -> Fs_compat.file_exists path
    | None -> false
  in
  `Assoc
    [ "field", `String detail.field
    ; "source", `String "live_meta"
    ; "live_source", `String "runtime_overlay"
    ; "default_source", Json_util.string_opt_to_json default_source_kind
    ; "default_source_kind", Json_util.string_opt_to_json default_source_kind
    ; "default_manifest_path", Json_util.string_opt_to_json default_manifest_path
    ; "default_manifest_exists", `Bool default_manifest_exists
    ; "default_missing", `Bool default_missing
    ; "default_value", detail.default_value
    ; "live_value", detail.live_value
    ]
;;

let source_provenance_json config (meta : keeper_meta) =
  let snapshot = keeper_default_source_snapshot meta.name in
  let override_details = live_override_details meta snapshot.defaults in
  let override_fields = List.map (fun detail -> detail.field) override_details in
  let resolution = Config_dir_resolver.resolve () in
  let live_meta_path = keeper_meta_path config meta.name in
  let default_manifest_path = snapshot.defaults.manifest_path in
  let default_source_kind = snapshot.source_kind in
  let default_config_error =
    Keeper_types_profile.keeper_toml_config_error_for_name meta.name
  in
  `Assoc
    ([ "live_meta_path", `String live_meta_path
     ; "live_meta", existing_path_json ~source:"runtime_overlay" live_meta_path
     ; "default_manifest_path", Json_util.string_opt_to_json default_manifest_path
     ; ( "default_manifest"
       , optional_existing_path_json ?source:default_source_kind default_manifest_path )
     ; "default_source_kind", Json_util.string_opt_to_json default_source_kind
     ; ( "default_config_error"
       , Json_util.option_to_yojson
           Keeper_types_profile.keeper_toml_config_error_to_json
           default_config_error )
     ; "active_config_root", `String resolution.config_root.path
     ; ( "active_config_root_source"
       , `String (Config_dir_resolver.source_to_string resolution.config_root.source) )
     ; "config_resolution", Config_dir_resolver.to_json resolution
     ; "precedence", `List [ `String "live_meta"; `String "toml"; `String "persona" ]
     ]
     @ cascade_catalog_source_fields resolution
     @ [ "has_live_override", `Bool (override_fields <> [])
       ; "override_fields", string_list_to_json override_fields
       ; ( "override_field_sources"
         , `List
             (List.map
                (override_field_source_json ~default_source_kind ~default_manifest_path)
                override_details) )
       ])
;;
