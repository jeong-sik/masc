(** Tool_misc — Miscellaneous operations (facade).

    Dispatches to sub-modules:
    - Tool_misc_transport: transport, websocket, webrtc handlers
    - Tool_misc_admin: auth, config, tool inventory, feature flag handlers

    Retains: dashboard, verify_handoff, gc, cleanup_zombies,
    tool_stats, tool_help, keeper_tool_catalog.

    @since 2.187.0 — Decomposed from monolithic tool_misc.ml *)

open Tool_args

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
}


(* ================================================================ *)
(* Handlers (retained in facade)                                    *)
(* ================================================================ *)

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
    (true, Yojson.Safe.to_string result)

let handle_gc ctx args =
  let days_raw = get_int args "days" 7 in
  let days = max 1 days_raw in
  if days_raw < 1 then
    Log.Misc.warn "masc_gc days=%d clamped to 1 (minimum guardrail)" days_raw;
  let gc_result = Room.gc ctx.config ~days () in
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
  (true, Yojson.Safe.to_string report)

let strip_mcp_prefix name =
  let prefix = "mcp__masc__" in
  let plen = String.length prefix in
  if String.length name > plen && String.sub name 0 plen = prefix
  then String.sub name plen (String.length name - plen)
  else name

let handle_tool_help _ctx args =
  let raw_name = String.trim (get_string args "tool_name" "") in
  if raw_name = "" then
    (false, "❌ tool_name is required")
  else
    let tool_name = strip_mcp_prefix raw_name in
    match Tool_help_registry.find_entry Config.raw_all_tool_schemas tool_name with
    | None -> (false, Printf.sprintf "❌ unknown tool: %s" raw_name)
    | Some entry ->
        (true, Yojson.Safe.to_string (Tool_help_registry.entry_json entry))

let handle_web_search _ctx args =
  Tool_misc_web_search.handle args

let handle_keeper_tool_catalog _ctx args =
  let include_hidden = get_bool args "include_hidden" false in
  let include_deprecated = get_bool args "include_deprecated" false in
  let limit = max 1 (min 500 (get_int args "limit" 50)) in
  let offset = max 0 (get_int args "offset" 0) in
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
  (true, Yojson.Safe.to_string json)

(* ================================================================ *)
(* Public re-exports from sub-modules                               *)
(* ================================================================ *)

let tool_inventory_json ctx ~include_hidden ~include_deprecated =
  let admin_ctx : Tool_misc_admin.context =
    { config = ctx.config; agent_name = ctx.agent_name }
  in
  Tool_misc_admin.tool_inventory_json admin_ctx ~include_hidden
    ~include_deprecated

(* ================================================================ *)
(* Dispatch (facade)                                                *)
(* ================================================================ *)

let dispatch ctx ~name ~args : result option =
  let admin_ctx : Tool_misc_admin.context =
    { config = ctx.config; agent_name = ctx.agent_name }
  in
  match name with
  | "masc_config" -> Some (Tool_misc_admin.handle_config args)
  | "masc_webrtc_offer" -> Some (Tool_misc_transport.handle_webrtc_offer args)
  | "masc_webrtc_answer" -> Some (Tool_misc_transport.handle_webrtc_answer args)
  | "masc_dashboard" -> Some (handle_dashboard ctx args)
  | "masc_verify_handoff" -> Some (handle_verify_handoff ctx args)
  | "masc_gc" -> Some (handle_gc ctx args)
  | "masc_cleanup_zombies" -> Some (handle_cleanup_zombies ctx args)
  | "masc_tool_stats" -> Some (handle_tool_stats ctx args)
  | "masc_tool_help" -> Some (handle_tool_help ctx args)
  | "masc_web_search" -> Some (handle_web_search ctx args)
  | "masc_tool_admin_snapshot" -> Some (Tool_misc_admin.handle_tool_admin_snapshot admin_ctx args)
  | "masc_tool_admin_update" -> Some (Tool_misc_admin.handle_tool_admin_update admin_ctx args)
  | "masc_keeper_tool_catalog" -> Some (handle_keeper_tool_catalog ctx args)
  | "masc_deep_review" -> Some (Tool_deep_review.handle_deep_review ctx.config args)
  | "masc_feature_flags" -> Some (Tool_misc_admin.handle_feature_flags args)
  | _ -> None

let schemas = Tool_schemas_misc.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only =
  [
    "masc_verify_handoff";
    "masc_tool_help";
    "masc_web_search";
    "masc_dashboard";
  ]

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_misc
           ~input_schema:s.input_schema
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ()))
    schemas
let looks_like_rss_payload = Tool_misc_web_search.looks_like_rss_payload
let parse_bing_rss_items = Tool_misc_web_search.parse_bing_rss_items
let parse_searxng_json = Tool_misc_web_search.parse_searxng_json
let parse_ddg_html = Tool_misc_web_search.parse_ddg_html
let parse_brave_json = Tool_misc_web_search.parse_brave_json
let parse_tavily_json = Tool_misc_web_search.parse_tavily_json
let parse_exa_json = Tool_misc_web_search.parse_exa_json
let parse_bing_search_json = Tool_misc_web_search.parse_bing_search_json
let redact_transport_error_detail = Tool_misc_web_search.redact_transport_error_detail
let web_search_provider_plan = Tool_misc_web_search.provider_plan
let web_search_simulate_for_test = Tool_misc_web_search.simulate_for_test
