(** Agent API HTTP handlers — activity, tool-metrics, timeline, relations.

    Extracted from server_routes_http_routes_dashboard.ml.
    Contains GET handler logic for /api/v1/agent-activity,
    /api/v1/tool-metrics, /api/v1/agent-timeline, /api/v1/agent-relations. *)

module Http = Http_server_eio

open Server_auth

let is_ascii_digit = function '0' .. '9' -> true | _ -> false

let decimal_float_syntax raw =
  let length = String.length raw in
  let rec digits index =
    if index < length && is_ascii_digit raw.[index]
    then digits (index + 1)
    else index
  in
  let integer_end = digits 0 in
  if integer_end = 0
  then false
  else
    let fraction_end =
      if integer_end < length && Char.equal raw.[integer_end] '.'
      then digits (integer_end + 1)
      else integer_end
    in
    if fraction_end < length && Char.equal raw.[fraction_end] '.'
    then false
    else
      let exponent_start =
        if fraction_end < length
           && (Char.equal raw.[fraction_end] 'e' || Char.equal raw.[fraction_end] 'E')
        then
          let index = fraction_end + 1 in
          if index < length && (Char.equal raw.[index] '+' || Char.equal raw.[index] '-')
          then index + 1
          else index
        else fraction_end
      in
      if exponent_start = fraction_end
      then fraction_end = length
      else exponent_start < length && digits exponent_start = length
;;

let positive_float_param ~name ~default = function
  | None -> Ok default
  | Some raw ->
    (match if decimal_float_syntax raw then float_of_string_opt raw else None with
     | Some v when Float.is_finite v && v > 0.0 -> Ok v
     | Some _ | None -> Error (name ^ " must be a positive number"))
;;

let positive_int_param ~name ~default = function
  | None -> Ok default
  | Some raw ->
    (match
       if String.length raw > 0 && String.for_all is_ascii_digit raw
       then int_of_string_opt raw
       else None
     with
     | Some v when v > 0 -> Ok v
     | Some _ | None -> Error (name ^ " must be a positive integer"))
;;

(* Per-agent tool-call rollup for [GET /api/v1/agent-activity].

   The route carried neither of the two protections the dashboard applies to a
   store scan, so [summarize_agent_activity] ran on the HTTP domain on every
   request and nothing was reused between them: measured 105 ms cold and 75 ms
   warm to produce 2.2 KB.

   [hours] is part of the cache key because it selects the window the scan
   covers — two windows are two answers, not one answer served twice. [since]
   is derived inside the compute rather than keyed on: it moves with wall-clock,
   so keying on it would make every request a miss. A cached window is therefore
   anchored up to one TTL in the past, which is what the 30 s tier means for a
   rollup whose default window is 24 h.

   Named rather than inlined in the route so the cache policy has one home and
   a test can reach it without an HTTP round trip. *)
let agent_activity_http_json ~(config : Workspace.config) ~hours : Yojson.Safe.t =
  let cache_key =
    Server_dashboard_http_core_cache.dashboard_query_cache_key
      config
      "agent_activity"
      [ ("hours", Some (string_of_float hours)) ]
  in
  Dashboard_cache.get_or_compute
    cache_key
    ~ttl:Server_dashboard_http_core_cache.live_cache_ttl_s
    (fun () ->
      Domain_pool_ref.submit_io_or_inline (fun () ->
        let since = Time_compat.now () -. (hours *. Masc_time_constants.hour) in
        let activities = Telemetry_eio.summarize_agent_activity config ~since in
        `Assoc
          [ ("hours", `Float hours);
            ("agents",
             `List
               (List.map
                  (fun (a : Telemetry_eio.agent_activity) ->
                     `Assoc
                       [ ("agent_id", `String a.agent_id);
                         ("tool_calls", `Int a.tool_calls);
                         ("success_count", `Int a.success_count);
                         ("failure_count", `Int a.failure_count);
                         ("first_seen", `Float a.first_seen);
                         ("last_seen", `Float a.last_seen);
                       ])
                  activities));
          ]))
;;

let add_agent_api_routes router =
  router
  (* Agent activity -- per-agent tool call stats from telemetry *)
  |> Http.Router.get "/api/v1/agent-activity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let hours_result =
           positive_float_param ~name:"hours" ~default:24.0 (Server_utils.query_param req "hours")
         in
         match hours_result with
         | Error detail ->
           Http.Response.json_value
             ~status:`Bad_request
             (`Assoc [ "error", `String detail ])
             reqd
         | Ok hours ->
         let json =
           agent_activity_http_json
             ~config:(Mcp_server.workspace_config state)
             ~hours
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  (* Tool metrics -- restart-safe aggregates plus an explicitly
     current-process persistence queue snapshot. *)
  |> Http.Router.get "/api/v1/tool-metrics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           Tool_unified.summary_report
             ~runtime_metrics:Runtime_observation.runtime_metrics_json
             ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  (* Agent timeline -- per-agent activity timeline for Observatory detail *)
  |> Http.Router.get "/api/v1/agent-timeline" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let agent_name =
           match Server_utils.query_param req "agent_name" with
           | Some n ->
               let trimmed = String.trim n in
               if trimmed <> "" then trimmed else ""
           | None -> ""
         in
         if agent_name = "" then
           Http.Response.json_value ~status:`Bad_request
             (`Assoc
                [
                  ( "error",
                    `String "agent_name query parameter is required" );
                ])
             reqd
         else
           let params =
             let ( let* ) = Result.bind in
             let* since_hours =
               positive_float_param
                 ~name:"since_hours"
                 ~default:4.0
                 (Server_utils.query_param req "since_hours")
             in
             let* limit =
               positive_int_param
                 ~name:"limit"
                 ~default:20
                 (Server_utils.query_param req "limit")
             in
             Ok (since_hours, limit)
           in
           match params with
           | Error detail ->
             Http.Response.json_value
               ~status:`Bad_request
               (`Assoc [ "error", `String detail ])
               reqd
           | Ok (since_hours, limit) ->
           let json =
             let config = Mcp_server.workspace_config state in
             Tool_agent_timeline.build_timeline
               ~load_chat:(fun ~agent_name ->
                 Keeper_chat_timeline_source.lines_for
                   ~base_dir:config.base_path ~keeper_name:agent_name)
               config
               ~agent_name ~since_hours ~limit
               ~include_tasks:true ~include_board:false
               ~include_tool_calls:true
           in
          Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  (* Agent relations -- collaboration network + trust edges *)
  |> Http.Router.get "/api/v1/agent-relations" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let agent_name =
           match Server_utils.query_param req "agent_name" with
           | Some n ->
               let trimmed = String.trim n in
               if trimmed <> "" then trimmed else ""
           | None -> ""
         in
         if agent_name = "" then
           Http.Response.json_value ~status:`Bad_request
             (`Assoc
                [
                  ( "error",
                    `String "agent_name query parameter is required" );
                ])
             reqd
         else
           let json = Dashboard_agent_relations.json ~agent_name () in
          Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
