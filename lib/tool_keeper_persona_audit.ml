open Tool_args
open Keeper_types
open Keeper_runtime

let json_bool_opt = function
  | Some value -> `Bool value
  | None -> `Null

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null

let existing_path_json ?(candidates = []) path_opt =
  let exists =
    match path_opt with
    | Some path -> Fs_compat.file_exists path
    | None -> false
  in
  `Assoc
    [
      ("path", Json_util.string_opt_to_json path_opt);
      ("exists", `Bool exists);
      ("candidates", `List (List.map (fun path -> `String path) candidates));
    ]

let dedupe_sorted_strings values =
  values
  |> List.map String.trim
  |> List.filter (fun value -> not (String.equal value ""))
  |> List.sort_uniq String.compare

let take limit values = List.filteri (fun index _ -> index < limit) values

let requested_names ctx args =
  let explicit_names =
    let names = get_string_list args "names" in
    (match get_string_opt args "name" with
     | Some name -> name :: names
     | None -> names)
    |> dedupe_sorted_strings
  in
  if Stdlib.List.length explicit_names > 0 then explicit_names
  else
    let registry_names =
      Keeper_registry.all ~base_path:ctx.config.base_path ()
      |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
    in
    registry_names @ configured_keeper_names ctx.config @ keeper_names ctx.config
    |> dedupe_sorted_strings

let status ctx (meta : keeper_meta) =
  let keepalive_running = Keeper_status_bridge.runtime_keepalive_running ctx.config meta in
  let agent_status =
    Keeper_exec_status.parse_agent_status ctx.config ~agent_name:meta.agent_name
  in
  let now_ts = Time_compat.now () in
  let diagnostic =
    Keeper_exec_status.keeper_diagnostic_json
      ~meta ~agent_status ~keepalive_running ~history_items:[] ~now_ts
    |> Keeper_exec_status.augment_keeper_diagnostic_json
         ~meta ~keepalive_running
         ~keepalive_started_at:
           (Keeper_status_bridge.runtime_keepalive_started_at ctx.config meta)
         ~now_ts
  in
  Keeper_exec_status.keeper_surface_status ~agent_status ~diagnostic

type active_goal_scope_audit = {
  active_goal_ids : string list;
  scoped_task_count : int;
  scoped_open_task_count : int;
  scoped_terminal_task_count : int;
  global_open_task_count : int;
  stale : bool;
}

let active_goal_scope_audit ctx (meta : keeper_meta) =
  let active_goal_ids = meta.active_goal_ids in
  let task_is_open (task : Masc_domain.task) =
    not (Masc_domain.task_status_is_terminal task.task_status)
  in
  let tasks = Coord.get_tasks_safe ctx.config in
  let count_open tasks =
    List.fold_left
      (fun acc task -> if task_is_open task then acc + 1 else acc)
      0 tasks
  in
  let scoped_tasks =
    if active_goal_ids = [] then []
    else
      List.filter
        (Keeper_runtime_contract.task_is_linked_to_keeper_goals active_goal_ids)
        tasks
  in
  let scoped_task_count = List.length scoped_tasks in
  let scoped_open_task_count = count_open scoped_tasks in
  let scoped_terminal_task_count = scoped_task_count - scoped_open_task_count in
  let global_open_task_count = count_open tasks in
  let stale =
    active_goal_ids <> [] && scoped_open_task_count = 0
    && global_open_task_count > 0
  in
  {
    active_goal_ids;
    scoped_task_count;
    scoped_open_task_count;
    scoped_terminal_task_count;
    global_open_task_count;
    stale;
  }

let active_goal_scope_audit_to_json audit =
  `Assoc
    [
      ( "active_goal_ids",
        `List (List.map (fun goal_id -> `String goal_id) audit.active_goal_ids) );
      ("scoped_task_count", `Int audit.scoped_task_count);
      ("scoped_open_task_count", `Int audit.scoped_open_task_count);
      ("scoped_terminal_task_count", `Int audit.scoped_terminal_task_count);
      ("global_open_task_count", `Int audit.global_open_task_count);
      ("stale", `Bool audit.stale);
      ( "next_action",
        if audit.stale then
          `String
            "update keeper active_goal_ids or create/link an eligible scoped task"
        else `Null );
    ]

let profile_candidates persona_name =
  let resolution = Config_dir_resolver.resolve () in
  (resolution.personas.path :: Config_dir_resolver.personas_dirs ())
  |> dedupe_sorted_strings
  |> List.map (fun root ->
         Filename.concat (Filename.concat root persona_name) "profile.json")

let item ctx requested_name =
  let meta_result = read_meta_resolved ctx.config requested_name in
  let resolved_name, runtime_meta, runtime_meta_error =
    match meta_result with
    | Ok (Some (name, meta)) -> (name, Some meta, None)
    | Ok None -> (requested_name, None, None)
    | Error msg -> (requested_name, None, Some msg)
  in
  let keeper_toml_candidate =
    Filename.concat (Config_dir_resolver.keepers_dir ()) (resolved_name ^ ".toml")
  in
  let keeper_toml_path =
    match keeper_toml_path_opt resolved_name with
    | Some path -> Some path
    | None -> Some keeper_toml_candidate
  in
  let keeper_toml_exists = Fs_compat.file_exists keeper_toml_candidate in
  let defaults_result = load_keeper_profile_defaults_result resolved_name in
  let default_source = keeper_default_source_snapshot resolved_name in
  let defaults =
    match defaults_result with
    | Ok defaults -> defaults
    | Error _ -> default_source.defaults
  in
  let toml_error =
    match defaults_result with
    | Ok _ -> None
    | Error msg -> Some msg
  in
  let explicit_persona_name =
    match defaults.persona_name with
    | Some name when not (String.equal (String.trim name) "") -> Some (String.trim name)
    | _ -> None
  in
  let default_source_kind = default_source.source_kind in
  let inferred_persona_name =
    resolved_persona_name ~keeper_name:resolved_name defaults |> String.trim
  in
  let inferred_persona_profile_path =
    match inferred_persona_name with
    | "" -> None
    | name -> persona_profile_path_opt name
  in
  let persona_name =
    match explicit_persona_name with
    | Some name -> Some name
    | None -> (
        match default_source_kind, inferred_persona_profile_path with
        | Some "persona", _ when not (String.equal inferred_persona_name "") ->
            Some inferred_persona_name
        | _, Some _ when not (String.equal inferred_persona_name "") ->
            Some inferred_persona_name
        | _ -> None)
  in
  let persona_candidates =
    match persona_name with
    | Some name -> profile_candidates name
    | None -> []
  in
  let persona_profile_path =
    match persona_name with
    | Some name -> (
        match persona_profile_path_opt name with
        | Some path -> Some path
        | None -> (
            match persona_candidates with
            | candidate :: _ -> Some candidate
            | [] -> None))
    | None -> None
  in
  let persona_profile_exists =
    match persona_profile_path with
    | Some path -> Fs_compat.file_exists path
    | None -> false
  in
  let persona_expected =
    Option.is_some explicit_persona_name
    || persona_profile_exists
    ||
    match default_source_kind with
    | Some "persona" -> true
    | _ -> false
  in
  let live_meta_path = keeper_meta_path ctx.config resolved_name in
  let live_meta_exists = Fs_compat.file_exists live_meta_path in
  let registry_entry =
    Keeper_registry.get ~base_path:ctx.config.base_path resolved_name
  in
  let keepalive_running =
    runtime_meta
    |> Option.map (Keeper_status_bridge.runtime_keepalive_running ctx.config)
  in
  let keepalive_started_at =
    match runtime_meta with
    | Some meta -> Keeper_status_bridge.runtime_keepalive_started_at ctx.config meta
    | None -> None
  in
  let runtime_status = runtime_meta |> Option.map (status ctx) in
  let active_goal_scope = runtime_meta |> Option.map (active_goal_scope_audit ctx) in
  let autoboot_enabled =
    match runtime_meta with
    | Some meta -> Some meta.autoboot_enabled
    | None -> defaults.autoboot_enabled
  in
  let paused = runtime_meta |> Option.map (fun meta -> meta.paused) in
  let dormant_autoboot_disabled =
    match runtime_meta, autoboot_enabled, paused, registry_entry with
    | Some _, Some false, (Some false | None), None -> true
    | _ -> false
  in
  let issues =
    let add cond issue acc = if cond then issue :: acc else acc in
    []
    |> add (not keeper_toml_exists) "missing_keeper_toml"
    |> add (Option.is_some toml_error) "toml_parse_error"
    |> add
         (persona_expected && not persona_profile_exists)
         "missing_persona_profile"
    |> add (not live_meta_exists) "missing_runtime_meta"
    |> add (Option.is_some runtime_meta_error) "runtime_meta_error"
    |> add
         (Option.is_some runtime_meta
          && Option.is_none registry_entry
          && not dormant_autoboot_disabled)
         "registry_missing"
    |> add
         (match paused with
          | Some true -> true
          | _ -> false)
         "keeper_paused"
    |> add
         (match runtime_meta with
          | Some meta when Stdlib.List.length meta.active_goal_ids = 0 -> true
          | _ -> false)
         "empty_active_goal_ids"
    |> add
         (match active_goal_scope with
          | Some scope when scope.stale -> true
          | _ -> false)
         "stale_active_goal_ids"
    |> add
         (match runtime_meta, autoboot_enabled, paused, keepalive_running with
          | Some _, (Some true | None), (Some false | None), Some false -> true
          | _ -> false)
         "keepalive_not_running"
    |> List.rev
  in
  let phase =
    registry_entry
    |> Option.map (fun (entry : Keeper_registry.registry_entry) ->
           Keeper_state_machine.phase_to_string entry.phase)
  in
  `Assoc
    [
      ("name", `String resolved_name);
      ( "requested_name",
        if String.equal requested_name resolved_name then `Null
        else `String requested_name );
      ( "keeper_toml",
        existing_path_json ~candidates:[ keeper_toml_candidate ] keeper_toml_path );
      ("default_source_kind", Json_util.string_opt_to_json default_source_kind);
      ("default_manifest_path", Json_util.string_opt_to_json defaults.manifest_path);
      ("toml_error", Json_util.string_opt_to_json toml_error);
      ("persona_name", Json_util.string_opt_to_json persona_name);
      ("explicit_persona_name", Json_util.string_opt_to_json explicit_persona_name);
      ("persona_profile", existing_path_json ~candidates:persona_candidates persona_profile_path);
      ( "runtime_meta",
        `Assoc
          [
            ("path", `String live_meta_path);
            ("exists", `Bool live_meta_exists);
            ("error", Json_util.string_opt_to_json runtime_meta_error);
          ] );
      ("registry_present", `Bool (Option.is_some registry_entry));
      ("phase", Json_util.string_opt_to_json phase);
      ("runtime_status", Json_util.string_opt_to_json runtime_status);
      ( "active_goal_scope",
        match active_goal_scope with
        | Some scope -> active_goal_scope_audit_to_json scope
        | None -> `Null );
      ("autoboot_enabled", json_bool_opt autoboot_enabled);
      ("dormant", `Bool dormant_autoboot_disabled);
      ( "dormant_reason",
        if dormant_autoboot_disabled then `String "autoboot_disabled" else `Null );
      ("paused", json_bool_opt paused);
      ("keepalive_running", json_bool_opt keepalive_running);
      ("keepalive_started_at", json_float_opt keepalive_started_at);
      ("issues", `List (List.map (fun issue -> `String issue) issues));
      ("ok", `Bool (Stdlib.List.length issues = 0));
    ]

let summary items =
  let issue_list item =
    match Yojson.Safe.Util.member "issues" item with
    | `List issues ->
        List.filter_map
          (function
            | `String issue -> Some issue
            | _ -> None)
          issues
    | _ -> []
  in
  let has_issue issue item = List.mem issue (issue_list item) in
  let count pred =
    List.fold_left (fun acc item -> if pred item then acc + 1 else acc) 0 items
  in
  let count_issue issue = count (has_issue issue) in
  let count_bool_field field =
    count (fun item ->
        match Yojson.Safe.Util.member field item with
        | `Bool true -> true
        | _ -> false)
  in
  let count_autoboot_disabled =
    count (fun item ->
        match Yojson.Safe.Util.member "autoboot_enabled" item with
        | `Bool false -> true
        | _ -> false)
  in
  let ok_count =
    count (fun item ->
        match Yojson.Safe.Util.member "ok" item with
        | `Bool true -> true
        | _ -> false)
  in
  `Assoc
    [
      ("total", `Int (List.length items));
      ("ok", `Int ok_count);
      ("with_issues", `Int (List.length items - ok_count));
      ("missing_keeper_toml", `Int (count_issue "missing_keeper_toml"));
      ("toml_parse_error", `Int (count_issue "toml_parse_error"));
      ("missing_persona_profile", `Int (count_issue "missing_persona_profile"));
      ("missing_runtime_meta", `Int (count_issue "missing_runtime_meta"));
      ("runtime_meta_error", `Int (count_issue "runtime_meta_error"));
      ("registry_missing", `Int (count_issue "registry_missing"));
      ("dormant_autoboot_disabled", `Int (count_bool_field "dormant"));
      ("autoboot_disabled", `Int count_autoboot_disabled);
      ("keeper_paused", `Int (count_issue "keeper_paused"));
      ("keepalive_not_running", `Int (count_issue "keepalive_not_running"));
      ("empty_active_goal_ids", `Int (count_issue "empty_active_goal_ids"));
      ("stale_active_goal_ids", `Int (count_issue "stale_active_goal_ids"));
    ]

let handle ctx args : tool_result =
  let names = requested_names ctx args in
  let invalid_names = List.filter (fun name -> not (validate_name name)) names in
  if Stdlib.List.length invalid_names > 0 then
    ( false,
      error_response_typed ~code:Validation_error
        (Printf.sprintf "invalid keeper name(s): %s"
           (String.concat ", " invalid_names)) )
  else
    let limit = get_int args "limit" 100 |> max 0 |> min 500 in
    let include_ok = get_bool args "include_ok" true in
    let repair = get_bool args "repair" false in
    let dry_run_repair = get_bool args "dry_run_repair" false in
    let audited_items = names |> take limit |> List.map (item ctx) in
    let returned_items =
      if include_ok then audited_items
      else
        List.filter
          (fun item ->
            match Yojson.Safe.Util.member "ok" item with
            | `Bool true -> false
            | _ -> true)
          audited_items
    in
    let repair_result =
      if repair || dry_run_repair then
        Some
          (if dry_run_repair then Keeper_goal_repair.dry_run ctx.config
           else Keeper_goal_repair.run ctx.config)
      else None
    in
    let resolution = Config_dir_resolver.resolve () in
    let roots =
      `Assoc
        [
          ("base_path", `String ctx.config.base_path);
          ("masc_root", `String (Coord.masc_root_dir ctx.config));
          ("config_resolution", Config_dir_resolver.to_json resolution);
          ( "personas_dirs",
            `List
              (List.map
                 (fun path -> `String path)
                 (Config_dir_resolver.personas_dirs ())) );
        ]
    in
    let base_fields =
      [
        ("tool", `String "masc_keeper_persona_audit");
        ("roots", roots);
        ("summary", summary audited_items);
        ("returned_count", `Int (List.length returned_items));
        ("items", `List returned_items);
      ]
    in
    let response_fields =
      match repair_result with
      | Some r ->
          ("goal_repair", Keeper_goal_repair.repair_result_to_yojson r)
          :: base_fields
      | None -> base_fields
    in
    (true, ok_response response_fields)
