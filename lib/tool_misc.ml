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

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let env_flag_enabled name =
  match Sys.getenv_opt name with
  | None -> false
  | Some raw ->
      let v = String.trim raw |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "y" || v = "on"

let encode_string_list values =
  `List (List.map (fun value -> `String value) values)

let pretty_json_string raw =
  try Yojson.Safe.from_string raw |> Yojson.Safe.pretty_to_string
  with Yojson.Json_error _ -> raw

let rec trim_trailing_slashes value =
  let len = String.length value in
  if len > 0 && value.[len - 1] = '/' then
    trim_trailing_slashes (String.sub value 0 (len - 1))
  else
    value

let configured_http_port () =
  Env_config_core.masc_http_port_int ()

let configured_http_host () =
  Env_config_core.masc_host ()

let ipaddr_is_unspecified = function
  | Ipaddr.V4 addr -> Ipaddr.V4.compare addr Ipaddr.V4.any = 0
  | Ipaddr.V6 addr -> Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0

let is_unspecified_host host =
  match Ipaddr.of_string (String.trim host) with
  | Ok ip -> ipaddr_is_unspecified ip
  | Error _ -> false

let normalize_advertised_host host =
  if is_unspecified_host host then "127.0.0.1" else host

let effective_http_base_url () =
  match Sys.getenv_opt "MASC_HTTP_BASE_URL" with
  | Some raw -> (
      match trim_nonempty raw with
      | Some value -> trim_trailing_slashes value
      | None ->
          let host = configured_http_host () |> normalize_advertised_host in
          Printf.sprintf "http://%s:%d" host (configured_http_port ()))
  | None ->
      let host = configured_http_host () |> normalize_advertised_host in
      Printf.sprintf "http://%s:%d" host (configured_http_port ())

let advertised_http_host_port () =
  let base_url = effective_http_base_url () in
  let uri = Uri.of_string base_url in
  let host =
    match Uri.host uri with
    | Some value -> normalize_advertised_host value
    | None -> configured_http_host () |> normalize_advertised_host
  in
  let port =
    match Uri.port uri with
    | Some value -> value
    | None -> (
        match Uri.scheme uri with
        | Some "https" -> 443
        | _ -> configured_http_port ())
  in
  (base_url, host, port)

let websocket_discovery_json () =
  let (_, host, _) = advertised_http_host_port () in
  let enabled = Server_ws_standalone.is_enabled () in
  let port = Server_ws_standalone.configured_port () in
  let base_fields =
    [
      ("enabled", `Bool enabled);
      ("listening", `Bool (Atomic.get Transport_metrics.ws_runtime_listening));
      ("listen_status", `String (Atomic.get Transport_metrics.ws_listen_status));
      ("mode", `String "standalone");
      ("discovery_path", `String "/ws");
      ("session_count", `Int (Server_mcp_transport_ws.session_count ()));
    ]
  in
  let fields =
    if enabled then
      base_fields
      @
      [
        ("ws_port", `Int port);
        ("ws_url", `String (Printf.sprintf "ws://%s:%d/" host port));
      ]
    else
      base_fields
  in
  `Assoc fields

let transport_status_json () =
  let (base_url, host, _) = advertised_http_host_port () in
  let grpc_enabled = Masc_grpc_server.is_enabled () in
  let grpc_port = Masc_grpc_server.configured_port () in
  let webrtc_enabled = Server_webrtc_transport.is_enabled () in
  `Assoc
    [
      ("streamable_http_default", `Bool true);
      ("allow_legacy_accept", `Bool (env_flag_enabled "MASC_ALLOW_LEGACY_ACCEPT"));
      ("legacy_endpoints_deprecated", `Bool true);
      ( "http",
        `Assoc
          [
            ("enabled", `Bool true);
            ("base_url", `String base_url);
            ("mcp_url", `String (base_url ^ "/mcp"));
            ("sse_url", `String (base_url ^ "/sse"));
          ] );
      ( "grpc",
        `Assoc
          ([
             ("enabled", `Bool grpc_enabled);
             ("listening", `Bool (Transport_metrics.grpc_listening ()));
             ("listen_status", `String (Atomic.get Transport_metrics.grpc_listen_status));
             ("port", `Int grpc_port);
             ("service", `String Masc_grpc_service.service_name);
             ("health_service", `String Masc_grpc_server.health_service_name);
           ]
          @ if grpc_enabled then
              [ ("url", `String (Printf.sprintf "grpc://%s:%d" host grpc_port)) ]
            else
              []) );
      ("websocket", websocket_discovery_json ());
      ( "webrtc",
        `Assoc
          ([
             ("enabled", `Bool webrtc_enabled);
             ("signaling_path", `String "/webrtc");
             ("offer_path", `String "/webrtc/offer");
             ("answer_path", `String "/webrtc/answer");
             ( "ice_server_urls",
               `List
                 (List.map
                    (fun url -> `String url)
                    (Server_webrtc_transport.configured_ice_server_urls ())) );
             ("pending_offers", `Int (Server_webrtc_transport.pending_offer_count ()));
             ("active_peers", `Int (Server_webrtc_transport.active_peer_count ()));
             ("live_connections", `Int (Server_webrtc_transport.live_webrtc_count ()));
             ("connected_channels", `Int (Server_webrtc_transport.connected_channel_count ()));
           ]
          @ if webrtc_enabled then
              [ ("signaling_url", `String (base_url ^ "/webrtc")) ]
            else
              []) );
    ]

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
      ("http_auth_strict", `Bool http_auth_strict);
      ("bind_host", `String bind_host);
      ("bind_is_loopback", `Bool bind_is_loopback);
      ("operator_remote_requires_token", `Bool true);
      ("credential_count", `Int (List.length credentials));
      ("credentials", `List credentials);
    ]

let handle_transport_status _ctx _args : result =
  let json = transport_status_json () in
  (true, Yojson.Safe.pretty_to_string json)

let handle_config_snapshot _ctx _args : result =
  let json = Env_config_introspect.to_json () in
  (true, Yojson.Safe.pretty_to_string json)

let handle_feature_flags _ctx args : result =
  let category_filter =
    match U.member "category" args with
    | `String c when String.trim c <> "" -> Some (String.lowercase_ascii (String.trim c))
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
    | Some cat -> List.filter (fun (f : Feature_flag_registry.flag) -> f.category = cat) flags
  in
  let json = `Assoc [
    ("total", `Int (List.length Feature_flag_registry.all_flags));
    ("shown", `Int (List.length flags));
    ("flags", `List (List.map Feature_flag_registry.flag_to_json flags));
    ("deprecated", `Int (List.length (Feature_flag_registry.deprecated_flags ())));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_websocket_discovery _ctx _args : result =
  let json = websocket_discovery_json () in
  (true, Yojson.Safe.pretty_to_string json)

let handle_webrtc_offer _ctx args : result =
  if not (Server_webrtc_transport.is_enabled ()) then
    error_result "webrtc transport disabled"
  else
  let*! agent_name = get_string_required args "agent_name" in
  let ice_candidates = get_string_list args "ice_candidates" in
  let fields =
    [
      ("agent_name", `String agent_name);
      ("ice_candidates", encode_string_list ice_candidates);
    ]
    @
    match get_string_opt args "dtls_fingerprint" with
    | Some fingerprint ->
        [ ("dtls_fingerprint", `String fingerprint) ]
    | None -> []
  in
  match
    Server_webrtc_transport.handle_offer_request
      (Yojson.Safe.to_string (`Assoc fields))
  with
  | Ok body -> (true, pretty_json_string body)
  | Error msg -> error_result msg

let handle_webrtc_answer _ctx args : result =
  if not (Server_webrtc_transport.is_enabled ()) then
    error_result "webrtc transport disabled"
  else
  let*! offer_id = get_string_required args "offer_id" in
  let*! agent_name = get_string_required args "agent_name" in
  let ice_candidates = get_string_list args "ice_candidates" in
  let body =
    `Assoc
      [
        ("offer_id", `String offer_id);
        ("agent_name", `String agent_name);
        ("ice_candidates", encode_string_list ice_candidates);
      ]
    |> Yojson.Safe.to_string
  in
  match Server_webrtc_transport.handle_answer_request body with
  | Ok response -> (true, pretty_json_string response)
  | Error msg -> error_result msg

let tool_inventory_json _ctx ~include_hidden ~include_deprecated =
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
           `Assoc
             ([
                ("name", `String schema.name);
                ("description", `String help_entry.short_description);
                ("enabled", `Bool true);
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

let handle_tool_admin_snapshot ctx args =
  let include_hidden = get_bool args "include_hidden" true in
  let include_deprecated = get_bool args "include_deprecated" true in
  let payload =
    `Assoc
      [
        ("status", `String "ok");
        ("generated_at", `String (Types.now_iso ()));
        ("auth", auth_snapshot_json ctx);
        ( "command_plane",
          `Assoc
            [
              ("policy_status", Command_plane_v2.policy_status_json ctx.config);
              ("enforcement_summary", enforcement_summary_json ());
            ] );
        ( "tool_inventory",
          tool_inventory_json ctx ~include_hidden ~include_deprecated );
      ]
  in
  (true, Yojson.Safe.pretty_to_string payload)

let handle_tool_admin_update ctx args =
  let section =
    get_string args "section" "" |> String.trim |> String.lowercase_ascii
  in
  match section with
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
                    ("enforcement", `String "none");
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
                    ("enforcement", `String "none");
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
  | "keeper_policy" | "persistent_agent_policy" ->
      (false, "keeper_policy and persistent_agent_policy sections removed with policy_mode purge")
  | _ ->
      (false, "section must be one of: auth | unit_policy")

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
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
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

let handle_config _ctx args : result =
  let cat = get_string_opt args "category" in
  let json = Env_config_introspect.to_json_filtered ?cat () in
  (true, Yojson.Safe.pretty_to_string json)

(* Dispatch function *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_config" -> Some (handle_config ctx args)
  | "masc_transport_status" -> Some (handle_transport_status ctx args)
  | "masc_websocket_discovery" -> Some (handle_websocket_discovery ctx args)
  | "masc_webrtc_offer" -> Some (handle_webrtc_offer ctx args)
  | "masc_webrtc_answer" -> Some (handle_webrtc_answer ctx args)
  | "masc_dashboard" -> Some (handle_dashboard ctx args)
  | "masc_verify_handoff" -> Some (handle_verify_handoff ctx args)
  | "masc_gc" -> Some (handle_gc ctx args)
  | "masc_cleanup_zombies" -> Some (handle_cleanup_zombies ctx args)
  | "masc_tool_stats" -> Some (handle_tool_stats ctx args)
  | "masc_tool_help" -> Some (handle_tool_help ctx args)
  | "masc_tool_admin_snapshot" -> Some (handle_tool_admin_snapshot ctx args)
  | "masc_tool_admin_update" -> Some (handle_tool_admin_update ctx args)
  | "masc_keeper_tool_catalog" -> Some (handle_keeper_tool_catalog ctx args)
  | "masc_deep_review" -> Some (Tool_deep_review.handle_deep_review ctx.config args)
  | "masc_config_snapshot" -> Some (handle_config_snapshot ctx args)
  | "masc_feature_flags" -> Some (handle_feature_flags ctx args)
  | _ -> None

let schemas = Tool_schemas_misc.schemas
