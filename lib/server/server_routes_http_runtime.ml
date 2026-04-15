
open Server_utils
open Server_auth

open Server_routes_http_common

module Http = Http_server_eio

let is_dashboard_spa_deep_link path =
  starts_with ~prefix:"/dashboard/" path
  && not (starts_with ~prefix:"/dashboard/assets/" path)
  && path <> "/dashboard/credits"

(** CORS preflight response headers *)
let cors_preflight_headers origin =
  [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers", cors_allow_headers_value);
    ("access-control-expose-headers", "Mcp-Session-Id, Mcp-Protocol-Version");
  ]

(** JSON-RPC error response helper *)
let json_rpc_error code message =
  Printf.sprintf
    {|{"jsonrpc":"2.0","error":{"code":%d,"message":"%s"},"id":null}|}
    code
    (String.escaped message)

let is_http_error_response = function
  | `Assoc fields ->
      let id_is_null =
        match List.assoc_opt "id" fields with
        | Some `Null -> true
        | _ -> false
      in
      let code =
        match List.assoc_opt "error" fields with
        | Some (`Assoc err_fields) ->
            (match List.assoc_opt "code" err_fields with
             | Some (`Int c) -> Some c
             | _ -> None)
        | _ -> None
      in
      id_is_null && (code = Some (-32700) || code = Some (-32600))
  | _ -> false

(** Server start time for uptime calculation *)
let server_start_time = Unix.gettimeofday ()

let configured_http_port () =
  Env_config_core.masc_http_port_int ()

let configured_http_host () =
  Env_config_core.masc_host ()

let advertised_host_port request =
  let (host, port) =
    parse_host_port
      (Httpun.Headers.get request.Httpun.Request.headers "host")
      (configured_http_host ()) (configured_http_port ())
  in
  (Transport_read_model.normalize_advertised_host host, port)

let websocket_discovery_json request =
  let (host, port) = advertised_host_port request in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~allow_legacy_accept:Server_routes_http_common.allow_legacy_accept ~host
      ~base_url:(Printf.sprintf "http://%s:%d" host port) ()
  in
  Transport_read_model.websocket_discovery_json ctx

let transport_json request =
  let (host, port) = advertised_host_port request in
  let ctx =
    Transport_read_model.make_http_context ~include_configured:true
      ~allow_legacy_accept:Server_routes_http_common.allow_legacy_accept ~host
      ~base_url:(Printf.sprintf "http://%s:%d" host port) ()
  in
  Transport_read_model.transport_status_json ctx

let health_path_diagnostics () =
  match current_server_state_opt () with
  | Some state ->
      Server_base_path_diagnostics.detect
        ?input_base_path:(Env_config_core.base_path_raw_opt ())
        ?env_masc_base_path:(Env_config_core.base_path_raw_opt ())
        ~effective_base_path:state.room_config.base_path
        ~effective_masc_root:(Coord.masc_root_dir state.room_config)
        ()
  | None ->
      let effective_base_path = default_base_path () in
      let effective_masc_root = Filename.concat effective_base_path ".masc" in
      Server_base_path_diagnostics.detect
        ?input_base_path:(Env_config_core.base_path_raw_opt ())
        ?env_masc_base_path:(Env_config_core.base_path_raw_opt ())
        ~effective_base_path ~effective_masc_root ()

let make_health_json ?(listener = "http/1.1") request =
  let uptime_secs = int_of_float (Unix.gettimeofday () -. server_start_time) in
  let uptime_str =
    if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
    else if uptime_secs < 3600 then Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
    else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)
  in
  let build = Build_identity.current () in
  `Assoc [
    ("status", `String "ok");
    ("server", `String "masc-mcp");
    ("version", `String build.release_version);
    ("release_version", `String build.release_version);
    ("build", Build_identity.to_yojson build);
    ( "protocol",
      `Assoc
        [
          ("default", `String mcp_protocol_version_default);
          ("listener", `String listener);
          ( "supported",
            `List (List.map (fun v -> `String v) mcp_protocol_versions) );
        ] );
    ("transport", transport_json request);
    ("paths", Server_base_path_diagnostics.to_yojson (health_path_diagnostics ()));
    ("uptime", `String uptime_str);
    ("sse_clients", `Int (Sse.client_count ()));
    ("startup", Server_startup_state.to_yojson ());
    ("subsystems", Subsystem_health.to_yojson ());
    ("feature_flags", let features = Dashboard_feature_health.get_all_features () in
      Dashboard_feature_health.overview_json features);
    ("gc", let s = Gc.stat () in `Assoc [
      ("minor_collections", `Int s.minor_collections);
      ("major_collections", `Int s.major_collections);
      ("compactions", `Int s.compactions);
      ("heap_words", `Int s.heap_words);
      ("live_words", `Int s.live_words);
      ("minor_heap_size", `Int (let c = Gc.get () in c.minor_heap_size));
    ]);
    ("keeper_fibers", `Int (Keeper_registry.count_running ()));
  ]

(** Health check handler *)
let health_handler request reqd =
  Http.Response.json
    (Yojson.Safe.to_string (make_health_json request))
    reqd

(** Liveness probe: responds 200 as soon as the HTTP accept loop is running.
    Does not depend on server_state initialization.
    Kubernetes/Railway liveness probe target. *)
let liveness_handler _request reqd =
  let startup = Server_startup_state.to_yojson () in
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("live", `Bool true);
           ("startup", startup);
         ])
  in
  Http.Response.json body reqd

(** Readiness probe: responds 200 only when server_state is initialized. *)
let readiness_handler _request reqd =
  let current = Server_startup_state.(!state) in
  if current.state_ready then
    Http.Response.json
      (Yojson.Safe.to_string
         (`Assoc
            [
              ("ready", `Bool true);
              ("phase", `String (Server_startup_state.phase_to_string current.phase));
              ("backend_mode", `String current.backend_mode);
            ]))
      reqd
  else
    Http.Response.json ~status:`Service_unavailable
      (Yojson.Safe.to_string
         (`Assoc
            [
              ("ready", `Bool false);
              ("phase", `String (Server_startup_state.phase_to_string current.phase));
              ("elapsed_sec", `Float (Server_startup_state.elapsed_since_start ()));
            ]))
      reqd

let board_post_detail_json ~response_format ~post_id =
  match Board_dispatch.get_post ~post_id with
  | Error _ ->
      (`Not_found, {|{"error":"Post not found"}|})
  | Ok post ->
      let author = Board.Agent_id.to_string post.author in
      let author_karma = Board_dispatch.get_agent_karma ~agent_name:author in
      let comments =
        match Board_dispatch.get_comments ~post_id with
        | Ok cs -> cs
        | Error _ -> []
      in
      let post_json = board_post_dashboard_json ~author_karma post in
      let comments_json = `List (List.map Board.comment_to_yojson comments) in
      let json =
        if String.equal (String.lowercase_ascii (String.trim response_format)) "flat" then
          match post_json with
          | `Assoc fields -> `Assoc (fields @ [ ("comments", comments_json) ])
          | _ -> `Assoc [ ("post", post_json); ("comments", comments_json) ]
        else
          `Assoc [ ("post", post_json); ("comments", comments_json) ]
      in
      (`OK, Yojson.Safe.to_string json)

let governance_case_status_filter_of_request request =
  ignore (query_param request "status");
  None

let governance_cases_json request ~base_path =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let include_test = bool_query_param request "include_test" ~default:false in
  let status_filter = governance_case_status_filter_of_request request in
  Dashboard_governance.cases_json ~base_path ~limit ~offset ~status_filter
    ~include_test

let governance_case_detail_json ~base_path ~case_id =
  let (status, json) = Dashboard_governance.case_detail_json ~base_path ~case_id in
  let http_status =
    match status with
    | `OK -> `OK
    | `Not_found -> `Not_found
  in
  (http_status, json)

(** CORS preflight handler *)
let options_handler request reqd =
  let origin = get_origin request in
  let headers = Httpun.Headers.of_list (
    ("content-length", "0") :: cors_preflight_headers origin
  ) in
  let response = Httpun.Response.create ~headers `No_content in
  Httpun.Reqd.respond_with_string reqd response ""
