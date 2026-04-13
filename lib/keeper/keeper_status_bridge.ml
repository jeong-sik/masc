(** Keeper status bridge helpers. *)

open Keeper_types

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)

let execution_session_state_json config (meta : keeper_meta) =
  let _ = config in
  let _ = meta in
  `String "removed"

let execution_session_bridge_json config (meta : keeper_meta) =
  let _ = config in
  let _ = meta in
  `Assoc
    [
      ("enabled", `Bool false);
      ("status", `String "removed");
    ]

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
      ("room_scope", `String meta.room_scope);
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
  |> add_if "coordination.room_scope"
       (match defaults.room_scope with
        | Some value ->
            let authored = String.trim value in
            authored <> "" && authored <> meta.room_scope
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

let runtime_registry_entry (config : Room_utils.config) name =
  Keeper_registry.get ~base_path:config.base_path name

let runtime_keepalive_running (config : Room_utils.config) (meta : keeper_meta) =
  Keeper_registry.is_running ~base_path:config.base_path meta.name

let runtime_keepalive_started_at (config : Room_utils.config)
    (meta : keeper_meta) =
  Keeper_registry.started_at ~base_path:config.base_path meta.name

let runtime_blocker_surface_of_registry_entry
    (entry_opt : Keeper_registry.registry_entry option) =
  match entry_opt with
  | Some
      {
        last_failure_reason =
          Some
            ((Keeper_registry.Ambiguous_partial_commit { kind; detail }) as reason);
        _;
      } ->
      let manual_reconcile =
        Keeper_registry.failure_reason_requires_manual_reconcile reason
      in
      let blocker_class, default_summary =
        match kind with
        | Keeper_registry.Post_commit_timeout ->
            ( "ambiguous_post_commit_timeout",
              if manual_reconcile
              then
                "Mutating tools committed before the turn timed out. Retry stayed disabled and manual reconcile is required."
              else
                "Mutating tools committed before the turn timed out. Retry stayed disabled, but the committed tools are reconcile-safe so manual reconcile is not required." )
        | Keeper_registry.Post_commit_failure ->
            ( "ambiguous_post_commit_failure",
              if manual_reconcile
              then
                "Mutating tools committed before the turn failed. Retry stayed disabled and manual reconcile is required."
              else
                "Mutating tools committed before the turn failed. Retry stayed disabled, but the committed tools are reconcile-safe so manual reconcile is not required." )
      in
      let summary =
        let trimmed = String.trim detail in
        if trimmed = ""
        then default_summary
        else if (not manual_reconcile)
                && (String_util.contains_substring_ci trimmed
                      "manual reconcile is required")
        then default_summary
        else trimmed
      in
      Some (blocker_class, summary, manual_reconcile)
  | _ -> None

let runtime_blocker_surface_of_reason (reason : string) =
  let trimmed = String.trim reason in
  if trimmed = "" then
    None
  else if String_util.contains_substring_ci trimmed "autonomous turn slot wait timeout"
  then
    Some ("autonomous_slot_wait_timeout", trimmed, false)
  else if String_util.contains_substring_ci trimmed "admission queue wait timeout"
  then
    Some ("admission_queue_wait_timeout", trimmed, false)
  else if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
          && String_util.contains_substring_ci trimmed "semaphore_wait_ms="
  then
    Some ("turn_timeout_after_queue_wait", trimmed, false)
  else if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
  then
    Some ("turn_timeout", trimmed, false)
  else if String_util.contains_substring_ci trimmed "completion contract"
          || String_util.contains_substring_ci trimmed "completion_contract"
  then
    Some ("completion_contract_violation", trimmed, false)
  else
    None

let runtime_blocker_fields_json
    (config : Room_utils.config)
    (meta : keeper_meta) =
  match Keeper_manual_reconcile.read config meta.name with
  | Some { status = Keeper_manual_reconcile.Pending; blocker_class; summary; _ } ->
      [
        ("runtime_blocker_class", `String blocker_class);
        ("runtime_blocker_summary", `String summary);
        ("runtime_blocker_manual_reconcile", `Bool true);
      ]
  | Some { status = Keeper_manual_reconcile.Cleared; _ } ->
      [
        ("runtime_blocker_class", `Null);
        ("runtime_blocker_summary", `Null);
        ("runtime_blocker_manual_reconcile", `Null);
      ]
  | None ->
      (match
         runtime_blocker_surface_of_registry_entry
           (runtime_registry_entry config meta.name)
       with
       | Some (blocker_class, summary, manual_reconcile) ->
           [
             ("runtime_blocker_class", `String blocker_class);
             ("runtime_blocker_summary", `String summary);
             ("runtime_blocker_manual_reconcile", `Bool manual_reconcile);
           ]
       | None ->
           let derived =
             match runtime_blocker_surface_of_reason meta.runtime.last_blocker with
             | Some blocker -> Some blocker
             | None ->
                 runtime_blocker_surface_of_reason
                   meta.runtime.proactive_rt.last_reason
           in
           match derived with
           | Some (blocker_class, summary, manual_reconcile) ->
               [
                 ("runtime_blocker_class", `String blocker_class);
                 ("runtime_blocker_summary", `String summary);
                 ("runtime_blocker_manual_reconcile", `Bool manual_reconcile);
               ]
           | None ->
               [
                 ("runtime_blocker_class", `Null);
                 ("runtime_blocker_summary", `Null);
                 ("runtime_blocker_manual_reconcile", `Null);
               ])

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
