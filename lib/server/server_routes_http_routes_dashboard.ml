
open Server_auth
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_keeper_stream

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream

let dedupe_tool_names names =
  Json_util.dedupe_keep_order
    (names |> List.map String.trim |> List.filter (fun name -> name <> ""))

let keeper_tools_response_json (meta : Keeper_types.keeper_meta) =
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let masc_count =
    List.length
      (List.filter (fun name -> String.starts_with ~prefix:"masc_" name) allowed)
  in
  let tool_preset = Keeper_types.tool_access_preset meta.tool_access in
  let tool_also_allow = Keeper_types.tool_access_also_allowlist meta.tool_access in
  let tool_custom_allowlist =
    Keeper_types.tool_access_custom_allowlist meta.tool_access
    |> Option.value ~default:[]
  in
  `Assoc
    [
      ("ok", `Bool true);
      ("tool_access", Keeper_types.tool_access_to_json meta.tool_access);
      ( "tool_policy_mode",
        `String
          (match Keeper_types.tool_access_custom_allowlist meta.tool_access with
           | Some _ -> "custom"
           | None -> "preset") );
      ( "tool_preset",
        match tool_preset with
        | Some preset -> `String (Keeper_types.tool_preset_to_string preset)
        | None -> `Null );
      ("tool_also_allow", `List (List.map (fun s -> `String s) tool_also_allow));
      ("tool_custom_allowlist", `List (List.map (fun s -> `String s) tool_custom_allowlist));
      ("resolved_allowlist", `List (List.map (fun s -> `String s) allowed));
      ("tool_denylist", `List (List.map (fun s -> `String s) meta.tool_denylist));
      ("active_masc_tool_count", `Int masc_count);
      ("total_active", `Int (List.length allowed));
    ]

(** Handle POST /api/v1/keepers/:name/tools.
    Extracted so it can be called from any prefix_post handler that
    catches POST /api/v1/keepers/* requests. *)
let handle_keeper_tools_post state req reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let req_path = Http.Request.path req in
    let prefix = "/api/v1/keepers/" in
    let suffix = "/tools" in
    let plen = String.length prefix in
    let slen = String.length suffix in
    let tlen = String.length req_path in
    let name = String.trim (String.sub req_path plen (tlen - plen - slen)) in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request {|{"error":"keeper name required"}|} reqd
    else
      let config = state.Mcp_server.room_config in
      match Keeper_types.read_meta config name with
      | Error msg ->
          Http.Response.json ~status:`Not_found
            (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg)) reqd
      | Ok None ->
          Http.Response.json ~status:`Not_found
            (Printf.sprintf {|{"error":"keeper %S not found"}|} name) reqd
      | Ok (Some meta) ->
          (try
             let args = Yojson.Safe.from_string body_str in
             let action = Safe_ops.json_string ~default:"" "action" args in
             let updated_meta =
               match action with
               | "set_policy" ->
                   let mode = Safe_ops.json_string ~default:"" "mode" args in
                   let preset_raw = Safe_ops.json_string_opt "preset" args in
                   let allow_present =
                     match Yojson.Safe.Util.member "allow" args with
                     | `Null -> false
                     | _ -> true
                   in
                   let allow = Safe_ops.json_string_list "allow" args |> dedupe_tool_names in
                   let also_allow =
                     Safe_ops.json_string_list "also_allow" args |> dedupe_tool_names
                   in
                   let deny =
                     Safe_ops.json_string_list "deny" args |> dedupe_tool_names
                   in
                   let tool_access_result =
                     match mode with
                     | "preset" -> (
                         match preset_raw with
                         | None -> Error "preset required when mode=preset"
                         | Some raw -> (
                             match Keeper_types.tool_preset_of_string raw with
                             | None ->
                                 Error
                                   (Printf.sprintf
                                      "invalid tool_preset '%s' (allowed: minimal, messaging, coding, research, full)"
                                      raw)
                             | Some preset ->
                                 Ok
                                   (Keeper_types.Preset
                                      { preset; also_allow })))
                    | "custom" ->
                        if not allow_present then
                          Error "allow required when mode=custom"
                        else
                        Ok (Keeper_types.Custom allow)
                     | "full" ->
                         Ok
                           (Keeper_types.Preset
                              { preset = Keeper_types.Full; also_allow = [] })
                     | "" ->
                         Error "mode required (preset|custom|full)"
                     | other ->
                         Error (Printf.sprintf "unknown mode: %s" other)
                   in
                   Result.map
                     (fun tool_access ->
                       {
                         meta with
                         tool_access;
                         tool_denylist = deny;
                         updated_at = Keeper_types.now_iso ();
                       })
                     tool_access_result
               | "" -> Error "action required (set_policy)"
               | other -> Error (Printf.sprintf "unknown action: %s" other)
             in
             (match updated_meta with
             | Error msg ->
                 Http.Response.json ~status:`Bad_request
                   (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg)) reqd
             | Ok meta' ->
                 (* force: user-initiated tool config is authoritative.
                    fresher_meta would discard this write if a concurrent
                    keeper turn updated meta between our read and write. *)
                 (match Keeper_types.write_meta ~force:true config meta' with
                  | Ok () ->
                      Http.Response.json ~compress:true ~request:req
                        (Yojson.Safe.to_string (keeper_tools_response_json meta')) reqd
                  | Error e ->
                      Http.Response.json ~status:`Internal_server_error
                        (Printf.sprintf {|{"error":"write failed: %s"}|} (String.escaped e)) reqd))
           with Yojson.Json_error e ->
             Http.Response.json ~status:`Bad_request
               (Printf.sprintf {|{"error":"invalid json: %s"}|} (String.escaped e)) reqd))

let rec add_routes ~sw ~clock router =
  router
  |> Http.Router.post "/api/v1/broadcast" (fun request reqd ->
       (* POST /api/v1/broadcast - HTTP API for external tools like autocov *)
       with_token_permission_auth ~permission:Types.CanBroadcast
         (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)
  |> Http.Router.post "/broadcast" (fun request reqd ->
       (* POST /broadcast - Alias for autocov compatibility *)
       with_token_permission_auth ~permission:Types.CanBroadcast
         (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)

  (* Batch dashboard endpoint: single request replaces 4 separate API calls *)
  |> Http.Router.get "/api/v1/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           `Assoc
             [
               ("error", `String "dashboard batch contract removed");
               ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
             ]
         in
         Http.Response.json ~status:`Gone ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/shell" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_shell_http_json ?clock:state.Mcp_server.clock ~request:req
             state.Mcp_server.room_config
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/logs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let limit =
           Server_utils.int_query_param req "limit" ~default:200
           |> max 1 |> min 3000
         in
         let min_level = match Server_utils.query_param req "level" with
           | Some v -> Log.level_to_int (Log.level_of_string v)
           | None -> 0
         in
         let since_seq =
           match Server_utils.query_param req "since_seq" with
           | None -> None
           | Some _ ->
               let seq = Server_utils.int_query_param req "since_seq" ~default:(-1) in
               if seq < 0 then None else Some seq
         in
         let module_filter = match Server_utils.query_param req "module" with
           | Some v -> v
           | None -> ""
         in
         let entries =
           Log.Ring.recent ~limit ~min_level ~module_filter ?since_seq ()
         in
         let json = Log.Ring.to_json entries in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/logs/tool-host-failures" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let fallback_agent = agent_from_request request in
           let report_result =
             try
               let json = Yojson.Safe.from_string body_str in
               Dashboard_tool_host_events.report_of_yojson ?fallback_agent json
             with Yojson.Json_error err ->
               Error ("invalid json: " ^ err)
           in
           match report_result with
           | Ok report ->
               Dashboard_tool_host_events.record ?fs:state.Mcp_server.fs
                 state.Mcp_server.room_config
                 report;
               Http.Response.json ~compress:true ~request:req {|{"ok":true}|}
                 reqd
           | Error message ->
               Http.Response.json ~status:`Bad_request ~request:req
                 (Yojson.Safe.to_string
                    (`Assoc [ ("ok", `Bool false); ("error", `String message) ]))
                 reqd)
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/config" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Env_config_introspect.to_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/namespace-truth" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_namespace_truth_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/room-truth" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_namespace_truth_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_execution_http_json ~state ~sw ~clock request in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/board" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_memory_http_json req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = dashboard_governance_http_json req ~base_path in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/planning" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_planning_http_json ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/session" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_session_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tools" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_tools_http_json
             ?actor:(agent_from_request request)
             state.Mcp_server.room_config
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission/briefing" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_briefing_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_proof_http_json ~state req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/surface-readiness" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let surface_id = Server_utils.query_param req "surface_id" in
         let json = Dashboard_surface_readiness.json ?surface_id () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/collaboration-evidence" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let session_id = Server_utils.query_param req "session_id" in
         let room_id = Server_utils.query_param req "room_id" in
         let json =
           Dashboard_collaboration_evidence.json ?session_id ?room_id
             ~config:state.Mcp_server.room_config ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/transport-health" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_transport_health_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/perf" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_perf_http_json state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/harness-health" (fun _request reqd ->
       with_public_read (fun state req reqd ->
         let since = Server_utils.query_param req "since" in
         let until = Server_utils.query_param req "until" in
         let json =
           Dashboard_harness_health.json ~config:state.Mcp_server.room_config
             ?since ?until ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) _request reqd)
  |> Http.Router.get "/api/v1/dashboard/feature-health" (fun _request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_feature_health.json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) _request reqd)

  (* ── Dashboard delete actions ── *)

  |> Http.Router.post "/api/v1/dashboard/board/delete" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "post_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"post_id\":\"...\"}"}|} reqd
             | Some post_id ->
             match Board_dispatch.delete_post ~post_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error _ ->
                 Http.Response.json ~status:`Not_found ~request:req
                   {|{"ok":false,"error":"post not found or delete failed"}|} reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"post_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/tasks/delete" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "task_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"task_id\":\"...\"}"}|} reqd
             | Some task_id ->
             let config = state.Mcp_server.room_config in
             match Task_dispatch.delete_task config ~task_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error _ ->
                 Http.Response.json ~status:`Not_found ~request:req
                   {|{"ok":false,"error":"task not found or delete failed"}|} reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"task_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/goals/delete" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "goal_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"goal_id\":\"...\"}"}|} reqd
             | Some goal_id ->
             let config = state.Mcp_server.room_config in
             match Goal_store.delete_goal config ~goal_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error msg ->
                 Http.Response.json ~status:`Not_found ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|} (String.escaped msg))
                   reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"goal_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/keepers/chat/stream" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_keeper_msg" (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           match parse_keeper_chat_stream_request body_str with
           | Ok payload ->
               handle_keeper_chat_stream ~sw ~clock state request reqd payload
           | Error message ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (keeper_chat_stream_error_json message))
         )
       ) request reqd)

  (* Keeper GET sub-routes: /config and /chat/history *)
  |> Http.Router.prefix_get "/api/v1/keepers/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/keepers/" in
         let plen = String.length prefix in
         let tlen = String.length req_path in
         let ends_with suffix =
           let slen = String.length suffix in
           tlen > plen + slen
           && String.sub req_path (tlen - slen) slen = suffix
         in
         let extract_name suffix =
           let slen = String.length suffix in
           String.trim (String.sub req_path plen (tlen - plen - slen))
         in
         if ends_with "/chat/history" then
           let name = extract_name "/chat/history" in
           if name = "" then
             respond_json_with_cors ~status:`Bad_request request reqd
               {|{"error":"missing keeper name"}|}
           else
             let base_dir = state.Mcp_server.room_config.base_path in
             let messages =
               Keeper_chat_store.load ~base_dir ~keeper_name:name
             in
             respond_json_with_cors ~status:`OK request reqd
               (Yojson.Safe.to_string (Keeper_chat_store.to_json_array messages))
         else if ends_with "/config" then
           let name = extract_name "/config" in
           if String.length name = 0 then
             Http.Response.json ~status:`Bad_request
               {|{"error":"keeper name is required"}|} reqd
           else
             let config = state.Mcp_server.room_config in
             let (st, json) =
               Dashboard_http_keeper.keeper_config_json config name
             in
             let status : Httpun.Status.t =
               match st with `OK -> `OK | `Not_found -> `Not_found
             in
             Http.Response.json ~status ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         else if ends_with "/trajectory" then
           let name = extract_name "/trajectory" in
           if String.length name = 0 then
             Http.Response.json ~status:`Bad_request
               {|{"error":"keeper name is required"}|} reqd
           else if not (Keeper_config.validate_name name) then
             Http.Response.json ~status:`Bad_request
               (Printf.sprintf {|{"error":"invalid keeper name: %S"}|}
                  (String.escaped name)) reqd
           else
             let config = state.Mcp_server.room_config in
             (match Keeper_types.read_meta config name with
              | Error e ->
                Http.Response.json ~status:`Internal_server_error
                  (Printf.sprintf {|{"error":"%s"}|} (String.escaped e)) reqd
              | Ok None ->
                Http.Response.json ~status:`Not_found
                  (Printf.sprintf {|{"error":"keeper %S not found"}|} name) reqd
              | Ok (Some m) ->
                let trajectory_default_limit = 50 in
                let trajectory_max_limit = 500 in
                let limit =
                  Server_utils.int_query_param req "limit"
                    ~default:trajectory_default_limit
                  |> max 1 |> min trajectory_max_limit
                in
                let masc_root = Filename.concat config.base_path ".masc" in
                let entries =
                  Trajectory.read_entries ~masc_root ~keeper_name:m.name
                    ~trace_id:m.runtime.trace_id
                in
                let total = List.length entries in
                let recent =
                  if total <= limit then entries
                  else
                    let drop = total - limit in
                    List.filteri (fun i _e -> i >= drop) entries
                in
                let json = `Assoc [
                  ("keeper", `String name);
                  ("trace_id", `String m.runtime.trace_id);
                  ("generation", `Int m.runtime.generation);
                  ("total_entries", `Int total);
                  ("showing", `Int (List.length recent));
                  ("entries", `List (List.map (Trajectory.entry_to_json ~result_max_len:2000) recent));
                ] in
                Http.Response.json ~compress:true ~request:req
                  (Yojson.Safe.to_string json) reqd)
         else
           Http.Response.json ~status:`Not_found
             {|{"error":"not found"}|} reqd
       ) request reqd)

  (* Keeper config or tools update.  This prefix_post catches ALL POST
     /api/v1/keepers/* requests.  We check the suffix BEFORE auth so that
     /tools gets with_tool_auth (localhost-friendly) while /config keeps
     with_token_permission_auth (admin token required). *)
  |> Http.Router.prefix_post "/api/v1/keepers/" (fun request reqd ->
       let _p = Http.Request.path request in
       let _pfx_len = 16 in (* String.length "/api/v1/keepers/" *)
       let _tl = "/tools" in let _tll = String.length _tl in let _pl = String.length _p in
       if _pl > _pfx_len + _tll && String.sub _p (_pl - _tll) _tll = _tl then begin
         with_tool_auth ~tool_name:"masc_keeper_up"
           (fun state req reqd ->
             handle_keeper_tools_post state req reqd
           ) request reqd
       end else begin
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let req_path = Http.Request.path req in
           let prefix = "/api/v1/keepers/" in
           let suffix = "/config" in
           let plen = String.length prefix in
           let slen = String.length suffix in
           let tlen = String.length req_path in
           if tlen > plen + slen
              && String.sub req_path 0 plen = prefix
              && String.sub req_path (tlen - slen) slen = suffix
           then
             let name =
               String.trim
                 (String.sub req_path plen (tlen - plen - slen))
             in
             if String.length name = 0 then
               Http.Response.json ~status:`Bad_request
                 {|{"error":"keeper name is required"}|} reqd
             else
               let config = state.Mcp_server.room_config in
               match Keeper_types.read_meta config name with
               | Error msg ->
                   Http.Response.json ~status:`Not_found
                     (Printf.sprintf {|{"error":"%s"}|}
                        (String.escaped msg))
                     reqd
               | Ok None ->
                   Http.Response.json ~status:`Not_found
                     (Printf.sprintf {|{"error":"keeper %S not found"}|} name)
                     reqd
               | Ok (Some meta0) ->
                   (try
                      let args = Yojson.Safe.from_string body_str in
                      let fields_opt =
                        match args with
                        | `Assoc fields -> Some fields
                        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _
                        | `String _ | `List _ ->
                            None
                      in
                      match fields_opt with
                      | Some fields ->
                          let body_name =
                            match List.assoc_opt "name" fields with
                            | Some (`String value) ->
                                let trimmed = String.trim value in
                                if trimmed = "" then None else Some trimmed
                            | _ -> None
                          in
                          if Option.is_some body_name
                             && body_name <> Some name
                          then
                            Http.Response.json ~status:`Bad_request
                              (Printf.sprintf
                                 {|{"error":"keeper name mismatch: route=%S body=%S"}|}
                                 name (Option.value ~default:"" body_name))
                              reqd
                          else
                            let args_with_name =
                              `Assoc (("name", `String name) :: List.remove_assoc "name" fields)
                            in
                            let keeper_ctx : _ Tool_keeper.context =
                              {
                                config;
                                agent_name;
                                sw;
                                clock;
                                proc_mgr = state.Mcp_server.proc_mgr;
                                net = state.Mcp_server.net;
                              }
                            in
                            (match Keeper_turn_up_args.parse keeper_ctx args_with_name with
                            | Error (_ok, msg) ->
                                Http.Response.json ~status:`Bad_request
                                  (Printf.sprintf {|{"error":"%s"}|}
                                     (String.escaped msg))
                                  reqd
                            | Ok parsed ->
                                let ok, msg =
                                  Keeper_turn_up_update.update_keeper keeper_ctx parsed meta0
                                in
                                if not ok then
                                  Http.Response.json ~status:`Bad_request
                                    (Printf.sprintf {|{"error":"%s"}|}
                                       (String.escaped msg))
                                    reqd
                                else
                                  let (_st, json) =
                                    Dashboard_http_keeper.keeper_config_json config name
                                  in
                                  Http.Response.json ~compress:true ~request:req
                                    (Yojson.Safe.to_string json) reqd)
                      | None ->
                          Http.Response.json ~status:`Bad_request
                            {|{"error":"request body must be a JSON object"}|}
                            reqd
                    with Yojson.Json_error e ->
                      Http.Response.json ~status:`Bad_request
                        (Printf.sprintf {|{"error":"invalid json: %s"}|}
                           (String.escaped e))
                        reqd)
           else
             Http.Response.json ~status:`Not_found
               {|{"error":"not found"}|} reqd
         )
       ) request reqd
       end)

  (* Keeper boot — POST /api/v1/keepers/:name/boot *)
  |> Http.Router.prefix_post "/api/v1/keepers/" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state agent_name req reqd ->
           let req_path = Http.Request.path req in
           let prefix = "/api/v1/keepers/" in
           let suffix = "/boot" in
           let plen = String.length prefix in
           let slen = String.length suffix in
           let tlen = String.length req_path in
           if tlen > plen + slen
              && String.sub req_path 0 plen = prefix
              && String.sub req_path (tlen - slen) slen = suffix
           then
             let name =
               String.trim
                 (String.sub req_path plen (tlen - plen - slen))
             in
             if String.length name = 0 then
               Http.Response.json ~status:`Bad_request
                 {|{"error":"keeper name is required"}|} reqd
             else
               let config = state.Mcp_server.room_config in
               let keeper_ctx : _ Tool_keeper.context =
                 {
                   config;
                   agent_name;
                   sw;
                   clock;
                   proc_mgr = state.Mcp_server.proc_mgr;
                   net = state.Mcp_server.net;
                 }
               in
               let args = `Assoc [("name", `String name)] in
               (match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_up" ~args with
               | Some (true, body) ->
                   Http.Response.json ~compress:true ~request:req
                     (Printf.sprintf {|{"ok":true,"action":"boot","name":"%s","detail":%s}|}
                        (String.escaped name) body)
                     reqd
               | Some (false, body) ->
                   Http.Response.json ~status:`Bad_request ~request:req
                     (Yojson.Safe.to_string
                        (`Assoc [("ok", `Bool false); ("error", `String body)]))
                     reqd
               | None ->
                   Http.Response.json ~status:`Internal_server_error ~request:req
                     {|{"ok":false,"error":"dispatch returned None"}|}
                     reqd)
           else
             Http.Response.json ~status:`Not_found
               {|{"error":"not found"}|} reqd
         ) request reqd)

  (* Keeper shutdown — POST /api/v1/keepers/:name/shutdown *)
  |> Http.Router.prefix_post "/api/v1/keepers/" (fun request reqd ->
       let _p = Http.Request.path request in
       let _pfx_len = 16 in (* String.length "/api/v1/keepers/" *)
       let _tl = "/tools" in let _tll = String.length _tl in let _pl = String.length _p in
       if _pl > _pfx_len + _tll && String.sub _p (_pl - _tll) _tll = _tl then begin
         with_tool_auth ~tool_name:"masc_keeper_up"
           (fun state req reqd ->
             handle_keeper_tools_post state req reqd
           ) request reqd
       end else begin
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state agent_name req reqd ->
           let req_path = Http.Request.path req in
           let prefix = "/api/v1/keepers/" in
           let suffix = "/shutdown" in
           let plen = String.length prefix in
           let slen = String.length suffix in
           let tlen = String.length req_path in
           if tlen > plen + slen
              && String.sub req_path 0 plen = prefix
              && String.sub req_path (tlen - slen) slen = suffix
           then
             let name =
               String.trim
                 (String.sub req_path plen (tlen - plen - slen))
             in
             if String.length name = 0 then
               Http.Response.json ~status:`Bad_request
                 {|{"error":"keeper name is required"}|} reqd
             else
               let config = state.Mcp_server.room_config in
               let keeper_ctx : _ Tool_keeper.context =
                 {
                   config;
                   agent_name;
                   sw;
                   clock;
                   proc_mgr = state.Mcp_server.proc_mgr;
                   net = state.Mcp_server.net;
                 }
               in
               let args = `Assoc [("name", `String name)] in
               (match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_down" ~args with
               | Some (true, _body) ->
                   Http.Response.json ~compress:true ~request:req
                     (Printf.sprintf {|{"ok":true,"action":"shutdown","name":"%s"}|}
                        (String.escaped name))
                     reqd
               | Some (false, body) ->
                   Http.Response.json ~status:`Bad_request ~request:req
                     (Yojson.Safe.to_string
                        (`Assoc [("ok", `Bool false); ("error", `String body)]))
                     reqd
               | None ->
                   Http.Response.json ~status:`Internal_server_error ~request:req
                     {|{"ok":false,"error":"dispatch returned None"}|}
                     reqd)
           else
             Http.Response.json ~status:`Not_found
               {|{"error":"not found"}|} reqd
         ) request reqd
       end)

  |> add_agent_api_routes
  |> add_autoresearch_routes
  |> add_repo_synthesis_routes

(* ── Agent API routes ─────────────────────────────────────────── *)

and add_agent_api_routes router =
  router
  (* Agent activity — per-agent tool call stats from telemetry *)
  |> Http.Router.get "/api/v1/agent-activity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let hours =
           match Server_utils.query_param req "hours" with
           | Some h -> (try float_of_string h with Failure _ -> 24.0)
           | None -> 24.0
         in
         let since = Time_compat.now () -. (hours *. 3600.0) in
         let activities =
           Telemetry_eio.summarize_agent_activity state.Mcp_server.room_config ~since
         in
         let json = `Assoc [
           ("hours", `Float hours);
           ("agents", `List (List.map (fun (a : Telemetry_eio.agent_activity) ->
             `Assoc [
               ("agent_id", `String a.agent_id);
               ("tool_calls", `Int a.tool_calls);
               ("success_count", `Int a.success_count);
               ("failure_count", `Int a.failure_count);
               ("first_seen", `Float a.first_seen);
               ("last_seen", `Float a.last_seen);
             ]) activities));
         ] in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Tool metrics — unified registry stats for dashboard (P4 Phase 4.5) *)
  |> Http.Router.get "/api/v1/tool-metrics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Tool_unified.summary_report () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Agent timeline — per-agent activity timeline for Observatory detail *)
  |> Http.Router.get "/api/v1/agent-timeline" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let agent_name =
           match Server_utils.query_param req "agent_name" with
           | Some n when String.trim n <> "" -> String.trim n
           | _ -> ""
         in
         if agent_name = "" then
           Http.Response.json ~status:`Bad_request
             {|{"error":"agent_name query parameter is required"}|} reqd
         else
           let since_hours =
             match Server_utils.query_param req "since_hours" with
             | Some h -> (try float_of_string h with Failure _ -> 4.0)
             | None -> 4.0
           in
           let limit =
             match Server_utils.query_param req "limit" with
             | Some l -> (try int_of_string l with Failure _ -> 20)
             | None -> 20
           in
           let json =
             Tool_agent_timeline.build_timeline
               state.Mcp_server.room_config
               ~agent_name ~since_hours ~limit
               ~include_tasks:true ~include_board:false
           in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Agent relations — collaboration network + trust edges from Neo4j *)
  |> Http.Router.get "/api/v1/agent-relations" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let agent_name =
           match Server_utils.query_param req "agent_name" with
           | Some n when String.trim n <> "" -> String.trim n
           | _ -> ""
         in
         if agent_name = "" then
           Http.Response.json ~status:`Bad_request
             {|{"error":"agent_name query parameter is required"}|} reqd
         else
           let json = Dashboard_agent_relations.json ~agent_name () in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd
       ) request reqd)

(* ── Autoresearch routes ───────────────────────────────────────── *)

and add_autoresearch_routes router =
  router
  (* Autoresearch loops list — all active + persisted loops *)
  |> Http.Router.get "/api/v1/autoresearch/loops" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json =
           Dashboard_http_autoresearch.autoresearch_loops_json ~base_path
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Autoresearch loop detail — single loop with full cycle history *)
  |> Http.Router.prefix_get "/api/v1/autoresearch/loops/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/autoresearch/loops/" in
         let loop_id =
           String.trim
             (String.sub req_path (String.length prefix)
                (String.length req_path - String.length prefix))
         in
         if String.length loop_id = 0 then
           Http.Response.json ~status:`Bad_request
             {|{"error":"loop_id is required"}|} reqd
         else
           let history_limit =
             Server_utils.int_query_param req "history_limit" ~default:100
             |> Server_utils.clamp ~min_v:0 ~max_v:1000
           in
           match
             Dashboard_http_autoresearch.autoresearch_loop_detail_json
               ~base_path ~loop_id ~history_limit
           with
           | Ok json ->
               Http.Response.json ~compress:true ~request:req
                 (Yojson.Safe.to_string json) reqd
           | Error msg ->
               Http.Response.json ~status:`Not_found
                 (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
                 reqd
           | exception Invalid_argument msg ->
               Http.Response.json ~status:`Not_found
                 (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
               reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/autoresearch/loops/retry" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_autoresearch_stop" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "loop_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"loop_id\":\"...\"}"}|}
                   reqd
             | Some loop_id ->
             let base_path = state.Mcp_server.room_config.base_path in
             (match Dashboard_http_autoresearch.validate_loop_id loop_id with
             | Error message ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                      (String.escaped message))
                   reqd
             | Ok () -> (
                 match
                   Dashboard_http_autoresearch.retry_loop_json ~base_path ~loop_id
                 with
                 | Ok result ->
                     Http.Response.json ~compress:true ~request:req
                       (Yojson.Safe.to_string result) reqd
                 | Error message ->
                     Http.Response.json ~status:`Bad_request ~request:req
                       (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                          (String.escaped message))
                       reqd))
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"loop_id\":\"...\"}"}|}
               reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/autoresearch/loops/start" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_autoresearch_start" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let base_path = state.Mcp_server.room_config.base_path in
             (match
               Dashboard_http_autoresearch.start_loop_json ~base_path ~args
             with
             | Ok result ->
                 Http.Response.json ~compress:true ~request:req
                   (Yojson.Safe.to_string result) reqd
             | Error message ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Yojson.Safe.to_string
                      (`Assoc [("ok", `Bool false); ("error", `String message)]))
                   reqd)
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid JSON body"}|}
               reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/autoresearch/loops/delete" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_autoresearch_stop" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "loop_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"loop_id\":\"...\"}"}|}
                   reqd
             | Some loop_id ->
             let base_path = state.Mcp_server.room_config.base_path in
             (match Dashboard_http_autoresearch.validate_loop_id loop_id with
             | Error message ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                      (String.escaped message))
                   reqd
             | Ok () -> (
                 match
                   Dashboard_http_autoresearch.delete_loop_json ~base_path ~loop_id
                 with
                 | Ok result ->
                     Http.Response.json ~compress:true ~request:req
                       (Yojson.Safe.to_string result) reqd
                 | Error message ->
                     Http.Response.json ~status:`Not_found ~request:req
                       (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                          (String.escaped message))
                       reqd))
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"loop_id\":\"...\"}"}|}
               reqd
         )
       ) request reqd)

(* ── Repo synthesis routes ─────────────────────────────────────── *)

and add_repo_synthesis_routes router =
  router
  |> Http.Router.get "/api/v1/dashboard/repo-synthesis" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let limit =
           match Server_utils.query_param req "limit" with
           | Some raw -> (try int_of_string raw with Failure _ -> 20)
           | None -> 20
         in
         let json =
           Dashboard_http_repo_synthesis.repo_synthesis_benchmarks_json
             ~base_path ~limit ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.prefix_get "/api/v1/repo-synthesis/benchmarks/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/repo-synthesis/benchmarks/" in
         let run_id =
           String.trim
             (String.sub req_path (String.length prefix)
                (String.length req_path - String.length prefix))
         in
         if String.length run_id = 0 then
           Http.Response.json ~status:`Bad_request
             {|{"error":"run_id is required"}|} reqd
         else
           match
             Dashboard_http_repo_synthesis.repo_synthesis_benchmark_detail_json
               ~base_path ~run_id
           with
           | Ok json ->
               Http.Response.json ~compress:true ~request:req
                 (Yojson.Safe.to_string json) reqd
           | Error msg ->
               Http.Response.json ~status:`Not_found
                 (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
                 reqd
       ) request reqd)
