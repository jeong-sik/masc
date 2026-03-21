(** Tool_misc_snapshots - JSON builders and snapshot helpers for admin tools *)

module U = Yojson.Safe.Util

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

let keeper_default_gate_config () : Eval_gate.gate_config =
  {
    max_cost_usd = 0.10;
    max_tool_calls_per_turn = 5;
    entropy_threshold = 2;
    destructive_check_enabled = true;
    allowlist_enabled = true;
    allowed_tools = [
      "keeper_board_get"; "keeper_board_post"; "keeper_board_comment"; "keeper_board_list";
      "keeper_read"; "keeper_fs_read";
      "keeper_memory_search";
      "keeper_time_now"; "keeper_context_status";
    ];
    denied_tools = [
      "keeper_bash"; "keeper_edit"; "keeper_fs_edit"; "keeper_github";
    ];
  }

let keeper_tool_policy_json _autonomy_level =
  let gate = keeper_default_gate_config () in
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
