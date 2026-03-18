(** Tool_misc - Miscellaneous operations

    Handles: dashboard, verify_handoff, gc, cleanup_zombies
*)

open Tool_args

module U = Yojson.Safe.Util

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
}

let json_string_option = function
  | Some value when String.trim value <> "" -> `String (String.trim value)
  | _ -> `Null

let bool_arg_opt args key =
  match U.member key args with
  | `Bool value -> Some value
  | _ -> None

let int_arg_opt args key =
  match U.member key args with
  | `Int value -> Some value
  | `Intlit raw -> Some (Safe_ops.int_of_string_with_default ~default:0 raw)
  | _ -> None

let category_list_arg_opt args key =
  match U.member key args with
  | `Null -> None
  | `List items ->
      let categories =
        items
        |> List.filter_map (function
             | `String raw ->
                 Mode.category_of_string (String.lowercase_ascii (String.trim raw))
             | _ -> None)
      in
      Some categories
  | _ -> None

let permission_to_json tool_name =
  match Auth.permission_for_tool tool_name with
  | Some permission -> `String (Types.show_permission permission)
  | None -> `Null

let auth_snapshot_json ctx =
  let cfg = Auth.load_auth_config ctx.config.base_path in
  let credentials =
    Auth.list_credentials ctx.config.base_path
    |> List.sort (fun (left : Types.agent_credential) right ->
           String.compare left.agent_name right.agent_name)
    |> List.map (fun (cred : Types.agent_credential) ->
           `Assoc
             [
               ("agent_name", `String cred.agent_name);
               ("role", `String (Types.agent_role_to_string cred.role));
               ("created_at", `String cred.created_at);
               ("expires_at", json_string_option cred.expires_at);
             ])
  in
  `Assoc
    [
      ("enabled", `Bool cfg.enabled);
      ("require_token", `Bool cfg.require_token);
      ("default_role", `String (Types.agent_role_to_string cfg.default_role));
      ("token_expiry_hours", `Int cfg.token_expiry_hours);
      ("tool_auth_strict", `Bool (Auth.is_tool_auth_strict_enabled ()));
      ("credential_count", `Int (List.length credentials));
      ("credentials", `List credentials);
    ]

let mode_snapshot_json ctx =
  let room_path = Room.masc_dir ctx.config in
  let cfg = Config.load room_path in
  let categories =
    Mode.all_categories
    |> List.map (fun category ->
           let enabled = List.mem category cfg.enabled_categories in
           `Assoc
             [
               ("name", `String (Mode.category_to_string category));
               ("description", `String (Mode.category_description category));
               ("enabled", `Bool enabled);
             ])
  in
  `Assoc
    [
      ("mode", `String (Mode.mode_to_string cfg.mode));
      ("mode_description", `String (Mode.mode_description cfg.mode));
      ("enabled_tool_count", `Int (List.length (Config.enabled_tool_schemas cfg.enabled_categories)));
      ("registered_tool_count", `Int (Tool_dispatch.registered_count ()));
      ("categories", `List categories);
      ("config_summary", Config.get_config_summary room_path);
    ]

let keeper_gate_config_for_level
    ~(autonomy_level : Keeper_autonomy.autonomy_level) : Eval_gate.gate_config =
  let base_allowed = [
    "keeper_board_post"; "keeper_board_comment"; "keeper_board_list";
    "keeper_read"; "keeper_fs_read";
    "keeper_memory_search";
    "keeper_time_now"; "keeper_context_status";
  ] in
  let base_denied = [
    "keeper_bash"; "keeper_edit"; "keeper_fs_edit"; "keeper_github";
  ] in
  match autonomy_level with
  | Keeper_autonomy.L4_Autonomous ->
      {
        max_cost_usd = 0.10;
        max_tool_calls_per_turn = 5;
        entropy_threshold = 2;
        destructive_check_enabled = true;
        allowlist_enabled = true;
        allowed_tools = "keeper_bash" :: base_allowed;
        denied_tools = List.filter (fun t -> t <> "keeper_bash") base_denied;
      }
  | Keeper_autonomy.L5_Independent ->
      {
        max_cost_usd = 0.50;
        max_tool_calls_per_turn = 10;
        entropy_threshold = 3;
        destructive_check_enabled = true;
        allowlist_enabled = false;
        allowed_tools = [];
        denied_tools = [];
      }
  | _ ->
      {
        max_cost_usd = 0.10;
        max_tool_calls_per_turn = 5;
        entropy_threshold = 2;
        destructive_check_enabled = true;
        allowlist_enabled = true;
        allowed_tools = base_allowed;
        denied_tools = base_denied;
      }

let keeper_tool_policy_json autonomy_level =
  match Keeper_contract.parse_autonomy_level autonomy_level with
  | Some level ->
      let gate = keeper_gate_config_for_level ~autonomy_level:level in
      `Assoc
        [
          ("configured_tool_policy", `String (if gate.allowlist_enabled then "allowlist" else "all"));
          ( "configured_tool_names",
            `List
              (if gate.allowlist_enabled
               then List.map (fun name -> `String name) gate.allowed_tools
               else []) );
          ("denied_tool_names", `List (List.map (fun name -> `String name) gate.denied_tools));
          ("max_tool_calls_per_turn", `Int gate.max_tool_calls_per_turn);
          ("destructive_check_enabled", `Bool gate.destructive_check_enabled);
        ]
  | None ->
      `Assoc
        [
          ("configured_tool_policy", `String "unknown");
          ("configured_tool_names", `List []);
          ("denied_tool_names", `List []);
          ("max_tool_calls_per_turn", `Null);
          ("destructive_check_enabled", `Null);
        ]

let keeper_policy_row ctx ~runtime_class (meta : Keeper_types.keeper_meta) =
  let status_json =
    Keeper_exec_status.parse_agent_status ctx.config ~agent_name:meta.agent_name
  in
  let status =
    match U.member "status" status_json with
    | `String value -> value
    | _ -> "unknown"
  in
  let policy_json =
    match keeper_tool_policy_json meta.autonomy_level with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc
    ([
       ("name", `String meta.name);
       ("runtime_class", `String runtime_class);
       ("agent_name", `String meta.agent_name);
       ("status", `String status);
       ("autonomy_level", `String meta.autonomy_level);
       ("policy_mode", `String meta.policy_mode);
       ("action_budget", `String meta.policy_action_budget);
       ("reward_model_path",
        if String.trim meta.policy_reward_model_path = "" then `Null
        else `String meta.policy_reward_model_path);
       ("active_model", `String (Keeper_exec_status.active_model_of_meta meta));
       ("allowed_models", `List (List.map (fun model -> `String model) meta.allowed_models));
       ("updated_at", `String meta.updated_at);
     ]
    @ policy_json)

let keeper_policies_json ctx =
  let resident_rows =
    Keeper_types.resident_keeper_names ctx.config
    |> List.filter_map (fun name ->
           match Keeper_types.read_meta ctx.config name with
           | Ok (Some meta) -> Some (keeper_policy_row ctx ~runtime_class:"resident_keeper" meta)
           | Ok None | Error _ -> None)
  in
  let persistent_rows =
    Keeper_types.persistent_agent_names ctx.config
    |> List.filter_map (fun name ->
           match Keeper_types.read_meta ctx.config name with
           | Ok (Some meta) -> Some (keeper_policy_row ctx ~runtime_class:"persistent_agent" meta)
           | Ok None | Error _ -> None)
  in
  `Assoc
    [
      ("resident_keepers", `List resident_rows);
      ("persistent_agents", `List persistent_rows);
    ]

let tool_inventory_json ctx ~include_hidden ~include_deprecated =
  let room_path = Room.masc_dir ctx.config in
  let cfg = Config.load room_path in
  (* Build reverse index: tool_name -> surface string list.
     Also index by backend_tool_name so keeper/privileged surfaces
     are attached to the public tool name they dispatch to. *)
  let surface_map : (string, string list) Hashtbl.t = Hashtbl.create 256 in
  let add_surface name s =
    let prev =
      match Hashtbl.find_opt surface_map name with Some l -> l | None -> []
    in
    if not (List.mem s prev) then Hashtbl.replace surface_map name (s :: prev)
  in
  List.iter
    (fun (seed : Capability_registry.capability_seed) ->
      let s = Capability_registry.surface_to_string seed.projection.surface in
      add_surface seed.projection.tool_name s;
      add_surface seed.projection.backend_tool_name s)
    (Capability_registry.all_projection_seeds_from Config.raw_all_tool_schemas);
  let schemas =
    Config.raw_all_tool_schemas
    |> List.filter (fun (schema : Types.tool_schema) ->
           Tool_catalog.is_visible ~include_hidden ~include_deprecated schema.name)
    |> List.sort (fun (left : Types.tool_schema) right -> String.compare left.name right.name)
  in
  let rows =
    schemas
    |> List.map (fun (schema : Types.tool_schema) ->
           let help_entry = Tool_help_registry.entry_of_schema schema in
           let category = Mode.tool_category schema.name in
           `Assoc
             ([
                ("name", `String schema.name);
                ("description", `String help_entry.short_description);
                ("category", `String (Mode.category_to_string category));
                ("category_description", `String (Mode.category_description category));
                ("enabled_in_current_mode", `Bool (Mode.is_tool_enabled cfg.enabled_categories schema.name));
                ("direct_call_allowed", `Bool (Tool_catalog.allow_direct_call schema.name));
                ("required_permission", permission_to_json schema.name);
                ("doc_refs", `List (List.map (fun value -> `String value) help_entry.doc_refs));
                ("prompt_hints", `List (List.map (fun value -> `String value) help_entry.prompt_hints));
                ("surfaces",
                 `List
                   (match Hashtbl.find_opt surface_map schema.name with
                   | Some ss -> List.map (fun s -> `String s) (List.rev ss)
                   | None -> []));
              ]
             @ Tool_catalog.metadata_to_fields schema.name))
  in
  `Assoc
    [
      ("count", `Int (List.length rows));
      ("tools", `List rows);
      ("surface_summary",
       Capability_registry.surface_snapshot_json Config.raw_all_tool_schemas);
    ]

let enforcement_summary_json () =
  `List
    [
      `Assoc
        [
          ("surface", `String "room.mode_categories");
          ("status", `String "enforced");
          ("reason",
           `String
             "Tool dispatch blocks tools whose category is disabled in the current room mode.");
        ];
      `Assoc
        [
          ("surface", `String "room.auth.permission_map");
          ("status", `String "conditional");
          ("reason",
           `String
             "Auth permission checks are enforced only when room auth is enabled.");
        ];
      `Assoc
        [
          ("surface", `String "tool_catalog.visibility");
          ("status", `String "enforced");
          ("reason",
           `String
             "Hidden tools are removed from default discovery and may be direct-call blocked.");
        ];
      `Assoc
        [
          ("surface", `String "keeper.eval_gate.allowed_tools");
          ("status", `String "enforced");
          ("reason",
           `String
             "Keeper autonomy uses Eval_gate allow/deny lists at tool-call time.");
        ];
      `Assoc
        [
          ("surface", `String "unit.policy.kill_switch");
          ("status", `String "enforced");
          ("reason",
           `String
             "Command-plane assignment blocks operations targeting units with kill-switch enabled.");
        ];
      `Assoc
        [
          ("surface", `String "unit.policy.frozen");
          ("status", `String "enforced");
          ("reason",
           `String
             "Command-plane assignment blocks operations targeting frozen units.");
        ];
      `Assoc
        [
          ("surface", `String "unit.policy.tool_allowlist");
          ("status", `String "advisory_only");
          ("reason",
           `String
             "Stored in CPv2 topology/policy JSON but not wired into runtime tool dispatch on main.");
        ];
      `Assoc
        [
          ("surface", `String "unit.policy.model_allowlist");
          ("status", `String "advisory_only");
          ("reason",
           `String
             "Stored in CPv2 topology/policy JSON but not wired into runtime model selection on main.");
        ];
    ]

let handle_tool_admin_snapshot ctx args =
  let include_hidden = get_bool args "include_hidden" true in
  let include_deprecated = get_bool args "include_deprecated" true in
  let payload =
    `Assoc
      [
        ("status", `String "ok");
        ("generated_at", `String (Types.now_iso ()));
        ("mode", mode_snapshot_json ctx);
        ("auth", auth_snapshot_json ctx);
        ( "command_plane",
          `Assoc
            [
              ("policy_status", Command_plane_v2.policy_status_json ctx.config);
              ("enforcement_summary", enforcement_summary_json ());
            ] );
        ("keeper_policies", keeper_policies_json ctx);
        ( "tool_inventory",
          tool_inventory_json ctx ~include_hidden ~include_deprecated );
      ]
  in
  (true, Yojson.Safe.pretty_to_string payload)

let apply_keeper_policy_update config ~runtime_class args =
  let name = get_string args "name" "" |> String.trim in
  let policy_mode_opt = get_string_opt args "policy_mode" |> Option.map String.trim in
  let action_budget_opt = get_string_opt args "action_budget" |> Option.map String.trim in
  let autonomy_level_opt = get_string_opt args "autonomy_level" |> Option.map String.trim in
  let reward_model_path_opt = get_string_opt args "reward_model_path" |> Option.map String.trim in
  let membership_ok =
    match runtime_class with
    | "resident_keeper" -> List.mem name (Keeper_types.resident_keeper_names config)
    | "persistent_agent" -> List.mem name (Keeper_types.persistent_agent_names config)
    | _ -> false
  in
  if not (Keeper_types.validate_name name) then
    Error "invalid keeper name"
  else if not membership_ok then
    Error
      (Printf.sprintf "%s not found in %s set" name runtime_class)
  else
    match Keeper_types.read_meta config name with
    | Error err -> Error err
    | Ok None -> Error (Printf.sprintf "keeper not found: %s" name)
    | Ok (Some meta) ->
        let policy_mode =
          match policy_mode_opt with
          | None -> Ok (Keeper_contract.policy_mode_of_string meta.policy_mode)
          | Some raw -> (
              match Keeper_contract.parse_policy_mode raw with
              | Some mode -> Ok mode
              | None -> Error (Printf.sprintf "invalid policy_mode: %s" raw))
        in
        let action_budget =
          match action_budget_opt with
          | None -> Ok (Keeper_contract.policy_action_budget_of_string meta.policy_action_budget)
          | Some raw -> (
              match Keeper_contract.parse_policy_action_budget raw with
              | Some budget -> Ok budget
              | None -> Error (Printf.sprintf "invalid action_budget: %s" raw))
        in
        let autonomy_level =
          match autonomy_level_opt with
          | None -> Ok meta.autonomy_level
          | Some raw -> (
              match Keeper_autonomy.autonomy_level_of_string raw with
              | Some level -> Ok (Keeper_contract.autonomy_level_to_storage_string level)
              | None -> Error (Printf.sprintf "invalid autonomy_level: %s" raw))
        in
        (match policy_mode, action_budget, autonomy_level with
        | Error err, _, _ | _, Error err, _ | _, _, Error err -> Error err
        | Ok policy_mode, Ok action_budget, Ok autonomy_level ->
            let reward_model_path_raw =
              match reward_model_path_opt with
              | Some value -> value
              | None -> meta.policy_reward_model_path
            in
            let reward_model_path =
              if reward_model_path_raw <> ""
                 && Filename.is_relative reward_model_path_raw
              then
                Filename.concat config.base_path reward_model_path_raw
              else
                reward_model_path_raw
            in
            let effective_reward_result =
              if Keeper_contract.policy_mode_is_learned policy_mode then
                Keeper_memory.load_keeper_reward_model reward_model_path
                |> Result.map (fun _ -> (reward_model_path, None))
              else
                Ok (reward_model_path, None)
            in
            match effective_reward_result with
            | Error err -> Error err
            | Ok (effective_reward_path, reward_model_version) ->
                let updated =
                  {
                    meta with
                    policy_mode = Keeper_contract.policy_mode_to_string policy_mode;
                    policy_action_budget =
                      Keeper_contract.policy_action_budget_to_string action_budget;
                    policy_reward_model_path = effective_reward_path;
                    autonomy_level;
                    updated_at = Types.now_iso ();
                  }
                in
                (match Keeper_types.write_meta config updated with
                | Error err -> Error err
                | Ok () ->
                    let policy_json =
                      match keeper_tool_policy_json updated.autonomy_level with
                      | `Assoc fields -> fields
                      | _ -> []
                    in
                    Ok
                      (`Assoc
                        ([
                           ("status", `String "ok");
                           ("runtime_class", `String runtime_class);
                           ("name", `String updated.name);
                           ("policy_mode", `String updated.policy_mode);
                           ("action_budget", `String updated.policy_action_budget);
                           ("autonomy_level", `String updated.autonomy_level);
                           ("reward_model_path", json_string_option (Some updated.policy_reward_model_path));
                           ("reward_model_version", json_string_option reward_model_version);
                         ]
                        @ policy_json)))
        )

let handle_tool_admin_update ctx args =
  let section =
    get_string args "section" "" |> String.trim |> String.lowercase_ascii
  in
  let room_path = Room.masc_dir ctx.config in
  match section with
  | "mode" ->
      let categories_opt = category_list_arg_opt args "enabled_categories" in
      let mode_opt =
        get_string_opt args "mode"
        |> Option.map (fun raw -> String.lowercase_ascii (String.trim raw))
      in
      let result =
        match categories_opt, mode_opt with
        | Some categories, _ ->
            let config =
              Config.set_categories ~actor:ctx.agent_name
                ~source:"masc_tool_admin_update:mode" room_path categories
            in
            Ok config
        | None, Some "custom" ->
            Error "mode=custom requires enabled_categories"
        | None, Some raw -> (
            match Mode.mode_of_string raw with
            | Some mode ->
                Ok
                  (Config.switch_mode ~actor:ctx.agent_name
                     ~source:"masc_tool_admin_update:mode" room_path mode)
            | None -> Error (Printf.sprintf "unknown mode: %s" raw))
        | None, None -> Error "mode or enabled_categories is required"
      in
      (match result with
      | Error err -> (false, "❌ " ^ err)
      | Ok _ ->
          let payload =
            `Assoc
              [
                ("status", `String "ok");
                ("section", `String "mode");
                ("result", mode_snapshot_json ctx);
              ]
          in
          (true, Yojson.Safe.pretty_to_string payload))
  | "auth" ->
      let current = Auth.load_auth_config ctx.config.base_path in
      let require_token =
        match bool_arg_opt args "require_token" with
        | Some value -> value
        | None -> current.require_token
      in
      let enabled_opt = bool_arg_opt args "enabled" in
      let default_role_result =
        match get_string_opt args "default_role" with
        | None -> Ok current.default_role
        | Some raw -> (
            match Types.agent_role_of_string (String.lowercase_ascii (String.trim raw)) with
            | Ok role -> Ok role
            | Error err -> Error err)
      in
      let expiry_hours =
        match int_arg_opt args "token_expiry_hours" with
        | Some value when value > 0 -> Ok value
        | Some _ -> Error "token_expiry_hours must be > 0"
        | None -> Ok current.token_expiry_hours
      in
      (match default_role_result, expiry_hours with
      | Error err, _ | _, Error err -> (false, "❌ " ^ err)
      | Ok default_role, Ok token_expiry_hours ->
          let room_secret =
            match enabled_opt with
            | Some true when not current.enabled ->
                Some (Auth.enable_auth ctx.config.base_path ~require_token)
            | Some false when current.enabled ->
                Auth.disable_auth ctx.config.base_path;
                None
            | _ -> None
          in
          let refreshed = Auth.load_auth_config ctx.config.base_path in
          let updated =
            {
              refreshed with
              require_token;
              default_role;
              token_expiry_hours;
              enabled =
                (match enabled_opt with Some value -> value | None -> refreshed.enabled);
            }
          in
          Auth.save_auth_config ctx.config.base_path updated;
          let payload =
            `Assoc
              [
                ("status", `String "ok");
                ("section", `String "auth");
                ("room_secret", json_string_option room_secret);
                ("result", auth_snapshot_json ctx);
              ]
          in
          (true, Yojson.Safe.pretty_to_string payload))
  | "unit_policy" ->
      (match Command_plane_v2.policy_update_json ctx.config ~actor:ctx.agent_name args with
      | Error err -> (false, Yojson.Safe.to_string (`Assoc [ ("status", `String "error"); ("message", `String err) ]))
      | Ok json ->
          let warnings =
            let policy_json = U.member "policy" args in
            let items = ref [] in
            if U.member "tool_allowlist" policy_json <> `Null then
              items :=
                `Assoc
                  [
                    ("field", `String "tool_allowlist");
                    ("status", `String "advisory_only");
                    ("reason",
                     `String
                       "Stored in CPv2 policy but not yet enforced by runtime tool dispatch.");
                  ]
                :: !items;
            if U.member "model_allowlist" policy_json <> `Null then
              items :=
                `Assoc
                  [
                    ("field", `String "model_allowlist");
                    ("status", `String "advisory_only");
                    ("reason",
                     `String
                       "Stored in CPv2 policy but not yet enforced by runtime model selection.");
                  ]
                :: !items;
            `List (List.rev !items)
          in
          let payload =
            `Assoc
              [
                ("status", `String "ok");
                ("section", `String "unit_policy");
                ("warnings", warnings);
                ("result", json);
              ]
          in
          (true, Yojson.Safe.pretty_to_string payload))
  | "keeper_policy" ->
      (match apply_keeper_policy_update ctx.config ~runtime_class:"resident_keeper" args with
      | Ok json ->
          (true, Yojson.Safe.pretty_to_string (`Assoc [ ("status", `String "ok"); ("section", `String "keeper_policy"); ("result", json) ]))
      | Error err -> (false, "❌ " ^ err))
  | "persistent_agent_policy" ->
      (match apply_keeper_policy_update ctx.config ~runtime_class:"persistent_agent" args with
      | Ok json ->
          (true, Yojson.Safe.pretty_to_string (`Assoc [ ("status", `String "ok"); ("section", `String "persistent_agent_policy"); ("result", json) ]))
      | Error err -> (false, "❌ " ^ err))
  | _ ->
      (false, "❌ section must be one of: mode | auth | unit_policy | keeper_policy | persistent_agent_policy")

(* Handlers *)

let handle_dashboard ctx args =
  let compact = get_bool args "compact" false in
  let scope_arg = String.lowercase_ascii (get_string args "scope" "all") in
  let scope =
    match scope_arg with
    | "all" -> Ok Dashboard.All
    | "current" -> Ok Dashboard.Current
    | other -> Error other
  in
  match scope with
  | Error other ->
      (false, Printf.sprintf "❌ Invalid dashboard scope '%s' (expected: all | current)" other)
  | Ok scope ->
      let output =
        if compact then Dashboard.generate_compact ~scope ctx.config
        else Dashboard.generate ~scope ctx.config
      in
      (true, output)

let handle_verify_handoff _ctx args =
  let original = get_string args "original" "" in
  let received = get_string args "received" "" in
  if original = "" || received = "" then
    (false, "❌ original and received are required")
  else
    let threshold =
      get_float args "threshold" (Level2_config.Drift_guard.default_threshold ())
    in
    let result =
      Drift_guard.verify_handoff ~original ~received ~threshold ()
      |> Drift_guard.result_to_json
    in
    (true, Yojson.Safe.pretty_to_string result)

let handle_gc ctx args =
  let days_raw = get_int args "days" 7 in
  let days = max 1 days_raw in
  if days_raw < 1 then
    Log.Misc.warn "masc_gc days=%d clamped to 1 (minimum guardrail)" days_raw;
  let gc_result = Room.gc ctx.config ~days () in
  (* Also expire pending decisions past TTL *)
  let expired =
    try Cp_lifecycle.check_expired_decisions ctx.config
    with exn ->
      Log.Misc.warn "check_expired_decisions failed: %s" (Printexc.to_string exn);
      0
  in
  let decision_note =
    if expired > 0 then Printf.sprintf "\n⏰ Expired %d pending decision(s) past TTL" expired
    else ""
  in
  (true, gc_result ^ decision_note)

let handle_cleanup_zombies ctx _args =
  (true, Room.cleanup_zombies ctx.config)

let handle_tool_stats _ctx args =
  let top_n = max 1 (min 100 (get_int args "top_n" 20)) in
  let all_tool_names =
    List.map (fun (s : Types.tool_schema) -> s.name)
      Config.all_tool_schemas
  in
  let report = Tool_registry.stats_report ~top_n ~all_tool_names in
  (true, Yojson.Safe.pretty_to_string report)

let handle_tool_help _ctx args =
  let tool_name = String.trim (get_string args "tool_name" "") in
  if tool_name = "" then
    (false, "❌ tool_name is required")
  else
    match Tool_help_registry.find_entry Config.raw_all_tool_schemas tool_name with
    | None -> (false, Printf.sprintf "❌ unknown tool: %s" tool_name)
    | Some entry ->
        (true, Yojson.Safe.pretty_to_string (Tool_help_registry.entry_json entry))

let handle_keeper_tool_catalog _ctx args =
  let include_hidden = get_bool args "include_hidden" false in
  let include_deprecated = get_bool args "include_deprecated" false in
  let limit = max 1 (min 500 (get_int args "limit" 50)) in
  let offset = max 0 (get_int args "offset" 0) in
  let tier_filter =
    match get_string_opt args "tier" |> Option.map String.lowercase_ascii with
    | None -> None
    | Some raw -> Tool_catalog.tier_of_string raw
  in
  let server_tools =
    (if include_hidden || include_deprecated then
       Config.all_tool_schemas
       |> List.filter (fun schema ->
              Tool_catalog.is_visible
                ~include_hidden
                ~include_deprecated
                schema.Types.name)
     else
       Config.visible_tool_schemas ())
    |> List.filter (fun schema -> String.length schema.Types.name >= 5
                                 && String.equal (String.sub schema.Types.name 0 5) "masc_")
    |> (match tier_filter with
        | None -> Fun.id
        | Some tier ->
            List.filter (fun schema -> Tool_catalog.is_in_tier tier schema.Types.name))
  in
  let tool_json (schema : Types.tool_schema) =
    `Assoc
      (("name", `String schema.name)
       :: Tool_catalog.metadata_to_fields schema.name)
  in
  let wrapped_internal_tools =
    Capability_registry.keeper_wrapped_internal_tools
  in
  let wrapped_server_names =
    Capability_registry.keeper_wrapped_server_tools
  in
  let server_only_tools =
    server_tools
    |> List.map (fun schema -> schema.Types.name)
    |> List.filter (fun name -> not (List.mem name wrapped_server_names))
  in
  let total_count = List.length server_tools in
  let paged_server_tools =
    server_tools
    |> List.filteri (fun i _ -> i >= offset && i < offset + limit)
  in
  let json =
    `Assoc
      [
        ("count", `Int total_count);
        ("limit", `Int limit);
        ("offset", `Int offset);
        ("server_tools", `List (List.map tool_json paged_server_tools));
        ("wrapped_internal_tools",
          `List (List.map (fun name -> `String name) wrapped_internal_tools));
        ("wrapped_server_tools",
          `List (List.map (fun name -> `String name) wrapped_server_names));
        ("server_only_tools",
          `List (List.map (fun name -> `String name) server_only_tools));
        ( "keeper_standard_tools",
          `List
            (List.map
               (fun name -> `String name)
               Capability_registry.keeper_safe_tool_names) );
        ( "keeper_privileged_tools",
          `List
            (List.map
               (fun name -> `String name)
               Capability_registry.keeper_privileged_tool_names) );
        ( "surface_snapshot",
          Capability_registry.surface_snapshot_json
            Config.raw_all_tool_schemas );
      ]
  in
  (true, Yojson.Safe.pretty_to_string json)

(** BUG-014: Purge test data (test-* prefix agents, tasks, messages).
    Requires confirm=true to execute. *)
let handle_purge_test_data ctx args =
  let confirm = get_bool args "confirm" false in
  if not confirm then
    (false, "Purge requires confirm=true. This will remove all test-* agents, tasks, and messages.")
  else begin
    let config = ctx.config in
    let removed = ref 0 in
    (* Remove test-* agent files *)
    let agents_path = Room.agents_dir config in
    if Sys.file_exists agents_path then
      Sys.readdir agents_path |> Array.iter (fun name ->
        if String.length name > 5 && String.sub name 0 5 = "test-" then begin
          (try Sys.remove (Filename.concat agents_path name)
           with Sys_error msg -> Log.Misc.warn "purge remove %s: %s" name msg);
          incr removed
        end);
    (* Remove test-* messages *)
    let messages_path = Room.messages_dir config in
    if Sys.file_exists messages_path then
      Sys.readdir messages_path |> Array.iter (fun name ->
        if String.length name > 5 && String.sub name 0 5 = "test-" then begin
          (try Sys.remove (Filename.concat messages_path name)
           with Sys_error msg -> Log.Misc.warn "purge remove %s: %s" name msg);
          incr removed
        end);
    (true, Printf.sprintf "Purged %d test-* files" !removed)
  end

(* Dispatch function *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_dashboard" -> Some (handle_dashboard ctx args)
  | "masc_verify_handoff" -> Some (handle_verify_handoff ctx args)
  | "masc_gc" -> Some (handle_gc ctx args)
  | "masc_cleanup_zombies" -> Some (handle_cleanup_zombies ctx args)
  | "masc_purge_test_data" -> Some (handle_purge_test_data ctx args)
  | "masc_tool_stats" -> Some (handle_tool_stats ctx args)
  | "masc_tool_help" -> Some (handle_tool_help ctx args)
  | "masc_tool_admin_snapshot" -> Some (handle_tool_admin_snapshot ctx args)
  | "masc_tool_admin_update" -> Some (handle_tool_admin_update ctx args)
  | "masc_keeper_tool_catalog" -> Some (handle_keeper_tool_catalog ctx args)
  | _ -> None

let schemas = Tool_schemas_misc.schemas
