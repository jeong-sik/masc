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

type web_search_hit = string * string * string

let max_web_search_query_length = 500

let whitespace_re = Re.Pcre.re "[ \t\r\n]+" |> Re.compile
let html_tag_re = Re.Pcre.re "<[^>]+>" |> Re.compile
let cdata_start_re = Re.str "<![CDATA[" |> Re.compile
let cdata_end_re = Re.str "]]>" |> Re.compile
let rss_re = Re.Pcre.re "<rss\\b" |> Re.compile
let channel_re = Re.Pcre.re "<channel\\b" |> Re.compile
let item_re = Re.Pcre.re "<item\\b[^>]*>([\\s\\S]*?)</item>" |> Re.compile
let title_re = Re.Pcre.re "<title>([\\s\\S]*?)</title>" |> Re.compile
let link_re = Re.Pcre.re "<link>([\\s\\S]*?)</link>" |> Re.compile
let description_re = Re.Pcre.re "<description>([\\s\\S]*?)</description>" |> Re.compile

let html_entity_replacements =
  [
    ("&amp;", "&");
    ("&lt;", "<");
    ("&gt;", ">");
    ("&quot;", "\"");
    ("&#39;", "'");
    ("&#039;", "'");
    ("&nbsp;", " ");
  ]
  |> List.map (fun (entity, replacement) ->
         (Re.str entity |> Re.compile, replacement))

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let normalize_spaces text =
  text |> Re.replace_string whitespace_re ~by:" " |> String.trim

let strip_html_tags text =
  Re.replace_string html_tag_re ~by:"" text

let strip_cdata text =
  text
  |> Re.replace_string cdata_start_re ~by:""
  |> Re.replace_string cdata_end_re ~by:""

let decode_html_entities text =
  let basic =
    html_entity_replacements
    |> List.fold_left
         (fun acc (entity_re, replacement) ->
           Re.replace_string entity_re ~by:replacement acc)
         text
  in
  let len = String.length basic in
  let buf = Buffer.create len in
  let decode_numeric entity =
    let body = String.sub entity 2 (String.length entity - 3) in
    try
      if String.length body > 1
         && (body.[0] = 'x' || body.[0] = 'X')
      then
        Some
          (int_of_string ("0" ^ body)
           |> Uchar.of_int
           |> Buffer.add_utf_8_uchar buf;
           "")
      else
        Some
          (int_of_string body
           |> Uchar.of_int
           |> Buffer.add_utf_8_uchar buf;
           "")
    with _ -> None
  in
  let rec loop index =
    if index >= len then
      Buffer.contents buf
    else if basic.[index] <> '&' then (
      Buffer.add_char buf basic.[index];
      loop (index + 1))
    else
      match String.index_from_opt basic index ';' with
      | None ->
          Buffer.add_char buf basic.[index];
          loop (index + 1)
      | Some semi ->
          let entity = String.sub basic index (semi - index + 1) in
          if String.length entity >= 4
             && String.sub entity 0 2 = "&#"
          then (
            match decode_numeric entity with
            | Some _ -> loop (semi + 1)
            | None ->
                Buffer.add_string buf entity;
                loop (semi + 1))
          else (
            Buffer.add_string buf entity;
            loop (semi + 1))
  in
  loop 0

let clean_search_text text =
  text |> strip_cdata |> strip_html_tags |> decode_html_entities |> normalize_spaces

let looks_like_rss_payload payload =
  let normalized = String.lowercase_ascii payload in
  String.contains normalized '<'
  && (Re.execp rss_re normalized || Re.execp channel_re normalized)

let valid_search_result_url url =
  let trimmed = String.trim url in
  if trimmed = "" then
    false
  else
    let uri = Uri.of_string trimmed in
    match Uri.scheme uri |> Option.map String.lowercase_ascii with
    | Some "http" | Some "https" -> true
    | _ -> false

let search_field field_re block =
  match Re.exec_opt field_re block with
  | None -> None
  | Some groups -> Some (Re.Group.get groups 1 |> clean_search_text)

let parse_bing_rss_items (payload : string) : web_search_hit list =
  Re.all item_re payload
  |> List.filter_map (fun groups ->
         let block = Re.Group.get groups 1 in
         match
           search_field title_re block,
           search_field link_re block,
           search_field description_re block
         with
         | Some title, Some url, Some snippet
           when title <> "" && valid_search_result_url url ->
             Some (title, url, snippet)
         | Some title, Some url, None
           when title <> "" && valid_search_result_url url ->
             Some (title, url, "")
         | _ -> None)

let take_results limit hits =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | hit :: rest -> loop (remaining - 1) (hit :: acc) rest
  in
  loop limit [] hits

(* --- DuckDuckGo HTML search backend --- *)

let ddg_result_re = Re.Pcre.re
  {|<a rel="nofollow" class="result__a" href="[^"]*uddg=([^&"]+)[^"]*">([^<]*(?:<b>[^<]*</b>[^<]*)*)</a>|}
  |> Re.compile

let ddg_snippet_re = Re.Pcre.re
  {|<a class="result__snippet"[^>]*>([^<]*(?:<b>[^<]*</b>[^<]*)*)</a>|}
  |> Re.compile

let parse_ddg_html (payload : string) : web_search_hit list =
  let results = Re.all ddg_result_re payload in
  let snippets = Re.all ddg_snippet_re payload in
  List.mapi (fun i groups ->
    let url_encoded = Re.Group.get groups 1 in
    let title_raw = Re.Group.get groups 2 in
    let url = Uri.pct_decode url_encoded in
    let title = clean_search_text title_raw in
    let snippet =
      match List.nth_opt snippets i with
      | Some sg -> clean_search_text (Re.Group.get sg 1)
      | None -> ""
    in
    (title, url, snippet)
  ) results

let fetch_ddg_html ~query =
  let search_url =
    "https://html.duckduckgo.com/html/?q=" ^ Uri.pct_encode query
  in
  match Tool_local_runtime_http.http_get_text_with_status ~timeout_sec:15 search_url with
  | Error e -> Error e
  | Ok (status_opt, payload) -> (
      match status_opt with
      | Some 200 -> Ok (search_url, payload)
      | None -> Error "search endpoint returned no HTTP status"
      | Some status ->
          Error
            (Printf.sprintf "search endpoint returned HTTP %d" status))

(* --- SearXNG JSON search backend (self-hosted, primary) --- *)

let searxng_base_url () =
  match Sys.getenv_opt "MASC_SEARXNG_URL" with
  | Some url -> url
  | None -> "http://localhost:8888"

let fetch_searxng ~query =
  let search_url =
    searxng_base_url () ^ "/search?q=" ^ Uri.pct_encode query ^ "&format=json"
  in
  match Tool_local_runtime_http.http_get_text_with_status ~timeout_sec:15 search_url with
  | Error e -> Error (Printf.sprintf "SearXNG: %s" e)
  | Ok (status_opt, payload) -> (
      match status_opt with
      | Some 200 -> Ok (search_url, payload)
      | Some status ->
          Error (Printf.sprintf "SearXNG returned HTTP %d" status)
      | None -> Error "SearXNG returned no HTTP status")

let parse_searxng_json (payload : string) : web_search_hit list =
  try
    let json = Yojson.Safe.from_string payload in
    let open Yojson.Safe.Util in
    json |> member "results" |> to_list
    |> List.filter_map (fun item ->
           let title = item |> member "title" |> to_string_option |> Option.value ~default:"" in
           let url = item |> member "url" |> to_string_option |> Option.value ~default:"" in
           let snippet =
             item |> member "content" |> to_string_option |> Option.value ~default:""
           in
           if title <> "" && url <> "" then Some (title, url, snippet)
           else None)
  with _ -> []

(* Legacy Bing RSS — kept as fallback *)
let fetch_bing_rss ~query =
  let search_url =
    "https://www.bing.com/search?format=rss&q=" ^ Uri.pct_encode query
  in
  match Tool_local_runtime_http.http_get_text_with_status ~timeout_sec:15 search_url with
  | Error e -> Error e
  | Ok (status_opt, payload) -> (
      match status_opt with
      | Some 200 -> Ok (search_url, payload)
      | None -> Error "search endpoint returned no HTTP status"
      | Some status ->
          Error
            (Printf.sprintf "search endpoint returned HTTP %d" status))

let web_search_result_json ~query ~search_url ~engine (hits : web_search_hit list) =
  let results =
    hits
    |> List.map (fun (title, url, snippet) ->
           `Assoc
             [
               ("title", `String title);
               ("url", `String url);
               ("snippet", `String snippet);
             ])
  in
  json_ok
    [
      ( "result",
        `Assoc
          [
            ("query", `String query);
            ("engine", `String engine);
            ("search_url", `String search_url);
            ("result_count", `Int (List.length hits));
            ("results", `List results);
          ] );
    ]

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
    (true, Yojson.Safe.pretty_to_string result)

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

let handle_web_search _ctx args =
  let query = String.trim (get_string args "query" "") in
  if query = "" then
    (false, json_error "query is required")
  else if String.length query > max_web_search_query_length then
    ( false,
      json_error
        (Printf.sprintf
           "query must be at most %d characters"
           max_web_search_query_length) )
  else
    let limit = max 1 (min 10 (get_int args "limit" 5)) in
    (* Primary: SearXNG (self-hosted). Fallback: DDG HTML. Fallback: Bing RSS. *)
    let try_ddg_then_bing () =
      match fetch_ddg_html ~query with
      | Ok (search_url, payload) ->
          let hits = parse_ddg_html payload |> take_results limit in
          if hits <> [] then
            (true, web_search_result_json ~query ~search_url ~engine:"duckduckgo" hits)
          else
            (match fetch_bing_rss ~query with
             | Ok (bing_url, rss_payload) when looks_like_rss_payload rss_payload ->
                 let bing_hits = parse_bing_rss_items rss_payload |> take_results limit in
                 (true, web_search_result_json ~query ~search_url:bing_url ~engine:"bing_rss" bing_hits)
             | _ -> (false, json_error "all search engines failed"))
      | Error _ ->
          (match fetch_bing_rss ~query with
           | Ok (bing_url, rss_payload) when looks_like_rss_payload rss_payload ->
               let bing_hits = parse_bing_rss_items rss_payload |> take_results limit in
               (true, web_search_result_json ~query ~search_url:bing_url ~engine:"bing_rss" bing_hits)
           | _ -> (false, json_error "all search engines failed"))
    in
    match fetch_searxng ~query with
    | Ok (search_url, payload) ->
        let hits = parse_searxng_json payload |> take_results limit in
        if hits <> [] then
          (true, web_search_result_json ~query ~search_url ~engine:"searxng" hits)
        else
          try_ddg_then_bing ()
    | Error _searxng_err ->
        try_ddg_then_bing ()

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
  (true, Yojson.Safe.pretty_to_string json)

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
