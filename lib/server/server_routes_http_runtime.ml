
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

(** Health check handler *)
let health_handler _request reqd =
  let uptime_secs = int_of_float (Unix.gettimeofday () -. server_start_time) in
  let uptime_str =
    if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
    else if uptime_secs < 3600 then Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
    else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)
  in
  let build = Build_identity.current () in
  let health_json = `Assoc [
    ("status", `String "ok");
    ("server", `String "masc-mcp");
    ("version", `String build.release_version);
    ("release_version", `String build.release_version);
    ("build", Build_identity.to_yojson build);
    ( "protocol",
      `Assoc
        [
          ("default", `String mcp_protocol_version_default);
          ( "supported",
            `List (List.map (fun v -> `String v) mcp_protocol_versions) );
        ] );
    ( "transport",
      `Assoc
        [
          ("streamable_http_default", `Bool true);
          ("allow_legacy_accept", `Bool allow_legacy_accept);
          ("legacy_endpoints_deprecated", `Bool true);
        ] );
    ("uptime", `String uptime_str);
    ("sse_clients", `Int (Sse.client_count ()));
    ("pg_pool", let max_size = Backend_core.configured_max_pool_size () in
      let shared = Council.Archive.has_shared_pool () in
      Backend_core.pool_stats_to_yojson {
        max_size;
        pool_count = (if shared then 3 else 5);
        shared_pool_injected = shared;
      });
    ("subsystems", Subsystem_health.to_yojson ());
  ] in
  Http.Response.json (Yojson.Safe.to_string health_json) reqd

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
  match query_param request "status" with
  | None -> None
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "pending_ruling" -> Some Council.Governance_v2.Pending_ruling
      | "ready_auto_execute" -> Some Council.Governance_v2.Ready_auto_execute
      | "needs_human_gate" -> Some Council.Governance_v2.Needs_human_gate
      | "executed" -> Some Council.Governance_v2.Executed
      | "blocked" -> Some Council.Governance_v2.Blocked
      | "closed" -> Some Council.Governance_v2.Closed
      | _ -> None)

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
