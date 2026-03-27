(** Keeper status team session bridge helpers. *)

open Keeper_types

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)
(* auto_team_session removed — keeper decides autonomously via Agent.run() *)
let linked_team_session config (meta : keeper_meta) =
  match meta.active_team_session_id with
  | Some session_id -> Team_session_store.load_session config session_id
  | None -> None

let team_session_state_json config (meta : keeper_meta) =
  match linked_team_session config meta with
  | Some session ->
      `String (Team_session_types.status_to_string session.status)
  | None -> `Null

let team_session_bridge_json config (meta : keeper_meta) =
  let session = linked_team_session config meta in
  let session_exists = Option.is_some session in
  let session_state =
    match session with
    | Some current ->
        `String (Team_session_types.status_to_string current.status)
    | None -> `Null
  in
  `Assoc
    [
      ("enabled", `Bool false);
      ("active_session_id",
       match meta.active_team_session_id with
       | Some session_id -> `String session_id
       | None -> `Null);
      ("session_exists", `Bool session_exists);
      ("session_state", session_state);
      ("last_started_at",
       if String.trim meta.last_team_session_started_at = "" then `Null
       else `String meta.last_team_session_started_at);
      ("start_count_total", `Int meta.team_session_start_count_total);
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

let auto_team_session_surface_json () =
  `Assoc
    [
      ("status", `String "removed");
      ("enabled", `Bool false);
    ]

let coordination_surface_json (meta : keeper_meta) =
  `Assoc
    [
      ("room_scope", `String meta.room_scope);
      ("scope_kind", `String meta.scope_kind);
      ("mention_targets", string_list_to_json meta.mention_targets);
      ("joined_room_ids", string_list_to_json meta.joined_room_ids);
    ]

let live_override_fields (meta : keeper_meta) (defaults : keeper_profile_defaults) :
    string list =
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
  |> add_if "prompt.soul_profile"
       (match defaults.soul_profile with
        | Some value -> value <> meta.soul_profile
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
  |> add_if "coordination.scope_kind"
       (match defaults.scope_kind with
        | Some value -> canonical_scope_kind value <> meta.scope_kind
        | None -> false)
  |> add_if "coordination.mention_targets"
       (defaults.mention_targets <> [] && defaults.mention_targets <> meta.mention_targets)
  |> add_if "runtime.presence_keepalive"
       (match defaults.presence_keepalive with
        | Some value -> value <> meta.presence_keepalive
        | None -> false)
  |> add_if "runtime.presence_keepalive_sec"
       (match defaults.presence_keepalive_sec with
        | Some value -> value <> meta.presence_keepalive_sec
        | None -> false)
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

let runtime_surface_json config (meta : keeper_meta) =
  let resident_spec =
    match read_resident_keeper config meta.name with
    | Ok spec_opt -> spec_opt
    | Error _ -> None
  in
  let keepalive_running = runtime_keepalive_running config meta in
  let fiber_health =
    match
      Keeper_registry.fiber_health_of ~base_path:config.base_path meta.name
    with
    | Fiber_unknown when keepalive_running -> Fiber_alive
    | health -> health
  in
  let registry_state =
    match runtime_registry_entry config meta.name with
    | Some entry -> Some (Keeper_registry.state_to_string entry.state)
    | None -> None
  in
  `Assoc
    [
      ("paused", `Bool meta.paused);
      ("registered", `Bool (Option.is_some resident_spec));
      ("resident_registered", `Bool (Option.is_some resident_spec));
      ("keepalive_running", `Bool keepalive_running);
      ("registry_state",
       match registry_state with
       | Some state -> `String state
       | None -> `Null);
      ( "fiber_health",
        `String (Keeper_exec_status.string_of_fiber_health fiber_health) );
      ("presence_keepalive", `Bool meta.presence_keepalive);
      ("presence_keepalive_sec", `Int meta.presence_keepalive_sec);
    ]

let source_provenance_json config (meta : keeper_meta) =
  let snapshot = keeper_default_source_snapshot meta.name in
  let override_fields = live_override_fields meta snapshot.defaults in
  let resident_path = resident_keeper_path config meta.name in
  `Assoc
    [
      ("live_meta_path", `String (keeper_meta_path config meta.name));
      ("resident_spec_path", `String resident_path);
      ("resident_spec_exists", `Bool (Sys.file_exists resident_path));
      ( "default_manifest_path",
        match snapshot.defaults.manifest_path with
        | Some path -> `String path
        | None -> `Null );
      ( "default_source_kind",
        match snapshot.source_kind with
        | Some kind -> `String kind
        | None -> `Null );
      ("precedence", `List [ `String "live_meta"; `String "resident_spec"; `String "toml"; `String "persona" ]);
      ("has_live_override", `Bool (override_fields <> []));
      ("override_fields", string_list_to_json override_fields);
    ]
