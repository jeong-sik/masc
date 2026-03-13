[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_tts_proxy
open Server_trpg_rest
open Server_dashboard_http

open Server_routes_http_common

module Http = Http_server_eio

let is_dashboard_spa_deep_link path =
  starts_with ~prefix:"/dashboard/" path
  && not (starts_with ~prefix:"/dashboard/assets/" path)
  && path <> "/dashboard/credits"
  && path <> "/dashboard/lodge"

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
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let gardener_json = Gardener.status_json () in
  let guardian_json = Guardian.status_json () in
  let sentinel_json = Sentinel.status_json () in
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
    ("lodge", lodge_json);
    ("gardener", gardener_json);
    ("guardian", guardian_json);
    ("sentinel", sentinel_json);
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

let debate_status_filter_of_request request =
  match query_param request "status" with
  | None -> None
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "open" -> Some Council.Debate.Open
      | "closed" -> Some Council.Debate.Closed
      | "pending" -> Some Council.Debate.Pending
      | _ -> None)

let council_debates_json request ~base_path =
  let config = Council.make_config ~base_path in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = limit + offset in
  let status_filter = debate_status_filter_of_request request in
  let debates = Council.DebateApi.list_all ~config ~status_filter ~limit:fetch_limit () in
  let paged = debates |> drop offset |> take limit in
  let items =
    List.map
      (fun (d : Council.Debate.debate) ->
        `Assoc
          [
            ("id", `String d.id);
            ("topic", `String d.topic);
            ("status", `String (Council.Debate.status_to_string d.status));
            ("argument_count", `Int (List.length d.arguments));
            ("created_at", `Float d.created_at);
            ("created_at_iso", `String (iso8601_of_unix d.created_at));
          ])
      paged
  in
  `Assoc
    [
      ("debates", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let council_sessions_json request =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let sessions = Council.ConsensusApi.list_active () |> drop offset |> take limit in
  let items =
    List.map
      (fun (s : Council.Consensus.session) ->
        `Assoc
          [
            ("id", `String s.id);
            ("topic", `String s.topic);
            ("initiator", `String s.initiator);
            ("votes", `Int (List.length s.votes));
            ("quorum", `Int s.quorum);
            ("threshold", `Float s.threshold);
            ("state", Council.Consensus.voting_state_to_yojson s.state);
            ("created_at", `Float s.created_at);
            ("created_at_iso", `String (iso8601_of_unix s.created_at));
          ])
      sessions
  in
  `Assoc
    [
      ("sessions", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let council_debate_summary_json ~base_path ~debate_id =
  let (status, json) =
    Dashboard_governance.debate_detail_json ~base_path ~debate_id
  in
  let http_status =
    match status with
    | `OK -> `OK
    | `Not_found -> `Not_found
  in
  (http_status, json)

let council_session_summary_json ~base_path ~session_id =
  let (status, json) =
    Dashboard_governance.consensus_detail_json ~base_path ~session_id
  in
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
