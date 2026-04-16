(** Keeper status bridge helpers. *)

open Keeper_types

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)



let drift_surface_json () =
  `Assoc
    [
      ("status", `String "unwired");
      ("enabled", `Null);
      ("min_turn_gap", `Null);
      ("count_total", `Null);
      ("last_reason", `Null);
    ]

let auto_execution_session_surface_json () =
  `Assoc
    [
      ("status", `String "removed");
      ("enabled", `Bool false);
    ]

let coordination_surface_json (meta : keeper_meta) =
  `Assoc
    [
      ("mention_targets", string_list_to_json meta.mention_targets);
      ("joined_room_ids", string_list_to_json meta.joined_room_ids);
    ]

let effective_declarative_cascade_name
    (defaults : keeper_profile_defaults)
    (meta : keeper_meta) =
  match defaults.cascade_name, defaults.manifest_path with
  | Some cascade_name, _ -> Keeper_cascade_profile.canonicalize cascade_name
  | None, Some _ -> Keeper_config.default_cascade_name
  | None, None -> Keeper_cascade_profile.canonicalize meta.cascade_name

let live_override_fields (meta : keeper_meta) (defaults : keeper_profile_defaults) :
    string list =
  let effective_cascade_name =
    effective_declarative_cascade_name defaults meta
  in
  let add_if label cond acc = if cond then label :: acc else acc in
  []
  |> add_if "prompt.goal"
       (match defaults.goal with
        | Some value -> normalize_goal_horizon_text value <> meta.goal
        | None -> false)
  |> add_if "prompt.short_goal"
       (match defaults.short_goal with
        | Some value -> value <> meta.short_goal
        | None -> false)
  |> add_if "prompt.mid_goal"
       (match defaults.mid_goal with
        | Some value -> value <> meta.mid_goal
        | None -> false)
  |> add_if "prompt.long_goal"
       (match defaults.long_goal with
        | Some value -> value <> meta.long_goal
        | None -> false)
  |> add_if "prompt.will"
       (match defaults.will with Some value -> value <> meta.will | None -> false)
  |> add_if "prompt.needs"
       (match defaults.needs with Some value -> value <> meta.needs | None -> false)
  |> add_if "prompt.desires"
       (match defaults.desires with Some value -> value <> meta.desires | None -> false)
  |> add_if "prompt.instructions"
       (match defaults.instructions with
        | Some value -> value <> meta.instructions
        | None -> false)
  |> add_if "coordination.mention_targets"
       (defaults.mention_targets <> [] && defaults.mention_targets <> meta.mention_targets)
  |> add_if "tools.tool_preset"
       (match defaults.tool_preset, Keeper_types.tool_access_preset meta.tool_access with
        | Some authored, Some active -> authored <> Keeper_types.tool_preset_to_string active
        | _ -> false)
  |> add_if "tools.tool_also_allow"
       (match defaults.tool_also_allow with
        | Some authored ->
            authored <> Keeper_types.tool_access_also_allowlist meta.tool_access
        | None -> false)
  |> add_if "tools.tool_denylist"
       (match defaults.tool_denylist with
        | Some authored -> authored <> meta.tool_denylist
        | None -> false)
  |> add_if "model.cascade_name"
       (effective_cascade_name <> meta.cascade_name)
  |> add_if "proactive.enabled"
       (match defaults.proactive_enabled with
        | Some value -> value <> meta.proactive.enabled
        | None -> false)
  |> List.rev

let runtime_registry_entry (config : Coord_utils.config) name =
  Keeper_registry.get ~base_path:config.base_path name

let runtime_keepalive_running (config : Coord_utils.config) (meta : keeper_meta) =
  Keeper_registry.is_running ~base_path:config.base_path meta.name

let runtime_keepalive_started_at (config : Coord_utils.config)
    (meta : keeper_meta) =
  Keeper_registry.started_at ~base_path:config.base_path meta.name

type runtime_blocker_surface = {
  blocker_class : string;
  summary : string;
  continue_gate : bool;
}

let runtime_blocker_surface_of_failure_reason
    (reason : Keeper_registry.failure_reason) =
  match reason with
  | Keeper_registry.Ambiguous_partial_commit { kind; detail } ->
      let blocker_class =
        match kind with
        | Keeper_registry.Post_commit_timeout ->
            "ambiguous_post_commit_timeout"
        | Keeper_registry.Post_commit_failure ->
            "ambiguous_post_commit_failure"
      in
      Some
        {
          blocker_class;
          summary = detail;
          continue_gate = true;
        }
  | _ -> None

let runtime_blocker_surface_of_reason (reason : string) =
  let trimmed = String.trim reason in
  if trimmed = "" then
    None
  else if
    String_util.contains_substring_ci trimmed
      "turn outcome ambiguous after committed mutating tool call(s)"
  then
    Some
      {
        blocker_class =
          (if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
           then "ambiguous_post_commit_timeout"
           else "ambiguous_post_commit_failure");
        summary = trimmed;
        continue_gate = true;
      }
  else if String_util.contains_substring_ci trimmed "autonomous turn slot wait timeout"
  then
    Some
      {
        blocker_class = "autonomous_slot_wait_timeout";
        summary = trimmed;
        continue_gate = false;
      }
  else if String_util.contains_substring_ci trimmed "admission queue wait timeout"
  then
    Some
      {
        blocker_class = "admission_queue_wait_timeout";
        summary = trimmed;
        continue_gate = false;
      }
  else if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
          && String_util.contains_substring_ci trimmed "semaphore_wait_ms="
  then
    Some
      {
        blocker_class = "turn_timeout_after_queue_wait";
        summary = trimmed;
        continue_gate = false;
      }
  else if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
  then
    Some
      {
        blocker_class = "turn_timeout";
        summary = trimmed;
        continue_gate = false;
      }
  else if String_util.contains_substring_ci trimmed "completion contract"
          || String_util.contains_substring_ci trimmed "completion_contract"
  then
    Some
      {
        blocker_class = "completion_contract_violation";
        summary = trimmed;
        continue_gate = false;
      }
  else
    None

let runtime_blocker_fields_json (config : Coord_utils.config)
    (meta : keeper_meta) =
  let derived =
    match runtime_registry_entry config meta.name with
    | Some entry -> (
        match entry.last_failure_reason with
        | Some reason -> runtime_blocker_surface_of_failure_reason reason
        | None -> None)
    | None -> None
  in
  let derived =
    match derived with
    | Some blocker -> Some blocker
    | None ->
        (match runtime_blocker_surface_of_reason meta.runtime.last_blocker with
         | Some blocker -> Some blocker
         | None ->
             runtime_blocker_surface_of_reason
               meta.runtime.proactive_rt.last_reason)
  in
  match derived with
  | Some blocker ->
      [
        ("runtime_blocker_class", `String blocker.blocker_class);
        ("runtime_blocker_summary", `String blocker.summary);
        ("runtime_blocker_continue_gate", `Bool blocker.continue_gate);
      ]
  | None ->
      [
        ("runtime_blocker_class", `Null);
        ("runtime_blocker_summary", `Null);
        ("runtime_blocker_continue_gate", `Bool false);
      ]

let trimmed_string_json value =
  let trimmed = String.trim value in
  if trimmed = "" then `Null else `String trimmed

let social_model_resolution_fields_json (meta : keeper_meta) =
  let resolved = Keeper_social_model.normalize_social_model meta.social_model in
  let recognized = Keeper_social_model.is_known_social_model meta.social_model in
  [
    ("social_model", `String resolved);
    ("configured_social_model", trimmed_string_json meta.social_model);
    ("social_model_recognized", `Bool recognized);
    ( "social_model_fallback",
      match Keeper_social_model.fallback_social_model meta.social_model with
      | Some fallback -> `String fallback
      | None -> `Null );
  ]

let social_runtime_fields_json (meta : keeper_meta) =
  social_model_resolution_fields_json meta
  @ [
      ("last_speech_act", trimmed_string_json meta.runtime.last_speech_act);
      ( "last_social_transition_reason",
        trimmed_string_json meta.runtime.last_social_transition_reason );
      ("last_blocker", trimmed_string_json meta.runtime.last_blocker);
      ("last_need", trimmed_string_json meta.runtime.last_need);
    ]

let runtime_surface_json config (meta : keeper_meta) =
  let keepalive_running = runtime_keepalive_running config meta in
  let fiber_health =
    match
      Keeper_registry.fiber_health_of ~base_path:config.base_path meta.name
    with
    | Fiber_unknown when keepalive_running -> Fiber_alive
    | health -> health
  in
  let phase =
    match runtime_registry_entry config meta.name with
    | Some entry -> Some (Keeper_state_machine.phase_to_string entry.phase)
    | None -> None
  in
  `Assoc
    ([
       ("paused", `Bool meta.paused);
       ("keepalive_running", `Bool keepalive_running);
       ("phase",
        match phase with
        | Some p -> `String p
        | None -> `Null);
       ( "fiber_health",
         `String (Keeper_exec_status.string_of_fiber_health fiber_health) );
     ]
     @ social_runtime_fields_json meta
     @ runtime_blocker_fields_json config meta)

let source_provenance_json config (meta : keeper_meta) =
  let snapshot = keeper_default_source_snapshot meta.name in
  let override_fields = live_override_fields meta snapshot.defaults in
  `Assoc
    [
      ("live_meta_path", `String (keeper_meta_path config meta.name));
      ( "default_manifest_path",
        match snapshot.defaults.manifest_path with
        | Some path -> `String path
        | None -> `Null );
      ( "default_source_kind",
        match snapshot.source_kind with
        | Some kind -> `String kind
        | None -> `Null );
      ("precedence", `List [ `String "live_meta"; `String "toml"; `String "persona" ]);
      ("has_live_override", `Bool (override_fields <> []));
      ("override_fields", string_list_to_json override_fields);
    ]
