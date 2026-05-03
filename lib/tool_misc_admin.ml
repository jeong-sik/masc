module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_misc_admin — Auth, config, tool inventory, and feature flag handlers.

    Extracted from tool_misc.ml to reduce god file size.
    Contains administrative tool handlers: auth config, tool admin snapshot/update,
    feature flags, enforcement summary, and tool inventory.

    @since 2.187.0 — God file decomposition Phase 1 *)

open Tool_args

module U = Yojson.Safe.Util

type tool_result = bool * string

(** SSOT for canonical `section` values accepted by
    [masc_tool_admin_update]. Adding a new section requires:
    (1) a new branch in the dispatcher match below,
    (2) this list gets the new string,
    (3) [Tool_schemas_misc.admin_section_enum_strings] mirror (sync test
    in [test_types.ml :: admin_section_ssot] catches drift).

    Issue #8546: schema advertised [auth; unit_policy] but the handler
    only implemented `auth`, so LLM clients following the schema got
    `"section must be one of: auth"` — fictional sections removed. *)
let valid_admin_section_strings : string list = [ "auth" ]

type context = {
  config: Coord.config;
  agent_name: string;
}

(* ================================================================ *)
(* Local helpers (duplicated from tool_misc to avoid circular deps) *)
(* ================================================================ *)

let json_string_option = function
  | Some value when not (String.equal (String.trim value) "") -> `String (String.trim value)
  | _ -> `Null

let bool_arg_opt args key =
  match U.member key args with
  | `Bool value -> Some value
  | _ -> None

let int_arg_opt args key =
  match U.member key args with
  | `Int value -> Some value
  | `Intlit raw -> Some (Option.value ~default:0 (Stdlib.int_of_string_opt raw))
  | _ -> None

(* ================================================================ *)
(* JSON builders                                                    *)
(* ================================================================ *)

let permission_to_json tool_name =
  match Auth.permission_for_tool tool_name with
  | Some permission -> `String (Types.show_permission permission)
  | None -> `Null

let auth_snapshot_json ctx =
  let cfg = Auth.load_auth_config ctx.config.base_path in
  let bind_host = Server_auth.http_auth_bind_host () in
  let bind_is_loopback = Server_auth.http_auth_bind_is_loopback () in
  let http_auth_strict = Server_auth.http_auth_strict_enabled () in
  let credentials =
    Auth.list_credentials ctx.config.base_path
    |> List.sort (fun (left : Types.agent_credential) right ->
           String.compare left.agent_name right.agent_name)
    |> List.map (fun (cred : Types.agent_credential) ->
           `Assoc
             [
               ("agent_name", `String cred.agent_name);
               ("admin", `Bool ((=) cred.role Types.Admin));
               ("created_at", `String cred.created_at);
               ("expires_at", json_string_option cred.expires_at);
             ])
  in
  `Assoc
    [
      ("enabled", `Bool cfg.enabled);
      ("require_token", `Bool cfg.require_token);
      ("token_expiry_hours", `Int cfg.token_expiry_hours);
      ("tool_auth_strict", `Bool (Auth.is_tool_auth_strict_enabled ()));
      ("http_auth_strict", `Bool http_auth_strict);
      ("bind_host", `String bind_host);
      ("bind_is_loopback", `Bool bind_is_loopback);
      ("operator_remote_requires_token", `Bool true);
      ("credential_count", `Int (List.length credentials));
      ("credentials", `List credentials);
    ]

let tool_inventory_json _ctx ~include_hidden ~include_deprecated =
  (* Returns all tool schemas from catalog with metadata.
     enabled_in_current_mode=false because this is dashboard context (no keeper).
     Keeper-specific tool availability is determined by keeper_allowed_tool_names. *)
  let surface_map : (string, string list) Hashtbl.t = Hashtbl.create 256 in
  let add_surface name s =
    let prev =
      match Hashtbl.find_opt surface_map name with Some l -> l | None -> []
    in
    if not (List.mem s prev) then Hashtbl.replace surface_map name (s :: prev)
  in
  Config.raw_all_tool_schemas
  |> List.iter (fun (schema : Types.tool_schema) ->
         if Tool_catalog.is_public_mcp schema.name then
           add_surface schema.name "public_mcp");
  List.iter
    (fun (seed : Capability_registry.capability_seed) ->
      let s = Capability_registry.surface_to_string seed.projection.surface in
      if not (String.equal s "public_mcp") then (
        add_surface seed.projection.tool_name s;
        add_surface seed.projection.backend_tool_name s))
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
           let metadata_fields =
             Tool_catalog.metadata_to_fields schema.name
             |> List.filter (fun (key, _value) -> not (String.equal key "surfaces"))
           in
           `Assoc
             ([
                ("name", `String schema.name);
                ("description", `String help_entry.short_description);
                ("enabled_in_current_mode", `Bool false);
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
             @ metadata_fields))
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
             "Keeper uses Eval_gate allow/deny lists at tool-call time.");
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

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

let handle_feature_flags args : tool_result =
  let category_filter =
    match U.member "category" args with
    | `String c when not (String.equal (String.trim c) "") -> Some (String.lowercase_ascii (String.trim c))
    | _ -> None
  in
  let only_overridden =
    match U.member "only_overridden" args with
    | `Bool true -> true
    | _ -> false
  in
  let flags =
    if only_overridden then Feature_flag_registry.overridden_flags ()
    else Feature_flag_registry.all_flags
  in
  let flags = match category_filter with
    | None -> flags
    | Some cat -> List.filter (fun (f : Feature_flag_registry.flag) -> String.equal f.category cat) flags
  in
  let deprecated_tools = Tool_catalog.deprecated_tool_entries in
  let json = `Assoc [
    ("total", `Int (List.length Feature_flag_registry.all_flags));
    ("shown", `Int (List.length flags));
    ("flags", `List (List.map Feature_flag_registry.flag_to_json flags));
    ("deprecated_flags", `Int (List.length (Feature_flag_registry.deprecated_flags ())));
    ("deprecated_tools", `Int (List.length deprecated_tools));
    ("deprecated_tool_names", `List (List.map (fun (name, _) -> `String name) deprecated_tools));
  ] in
  (true, Yojson.Safe.to_string json)

let handle_config args : tool_result =
  let cat = get_string_opt args "category" in
  let json = Env_config_introspect.to_json_filtered ?cat () in
  (true, Yojson.Safe.to_string json)

let handle_tool_admin_snapshot ctx args =
  let include_hidden = get_bool args "include_hidden" true in
  let include_deprecated = get_bool args "include_deprecated" true in
  let payload =
    `Assoc
      [
        ("status", `String "ok");
        ("generated_at", `String (Types.now_iso ()));
        ("auth", auth_snapshot_json ctx);
        ( "tool_inventory",
          tool_inventory_json ctx ~include_hidden ~include_deprecated );
      ]
  in
  (true, Yojson.Safe.to_string payload)

let handle_tool_admin_update ctx args =
  let section =
    get_string args "section" "" |> String.trim |> String.lowercase_ascii
  in
  match section with
  | "auth" ->
      let current = Auth.load_auth_config ctx.config.base_path in
      if not ((=) (U.member "default_role" args) `Null) then
        (false, "default_role is no longer supported")
      else
      let require_token =
        match bool_arg_opt args "require_token" with
        | Some value -> value
        | None -> current.require_token
      in
      let enabled_opt = bool_arg_opt args "enabled" in
      let expiry_hours =
        match int_arg_opt args "token_expiry_hours" with
        | Some value when value > 0 -> Ok value
        | Some _ -> Error "token_expiry_hours must be > 0"
        | None -> Ok current.token_expiry_hours
      in
      (match expiry_hours with
      | Error err -> (false, err)
      | Ok token_expiry_hours ->
          let room_secret =
            match enabled_opt with
            | Some true when not current.enabled ->
                let (secret, _bootstrap) =
                  Auth.enable_auth ctx.config.base_path ~require_token ~agent_name:ctx.agent_name
                in
                Some secret
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
          (true, Yojson.Safe.to_string payload))
  | _ ->
      (false,
       Printf.sprintf "section must be one of: %s"
         (String.concat " | " valid_admin_section_strings))
