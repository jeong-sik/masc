(** Agent API HTTP handlers — activity, tool-metrics, timeline.

    Extracted from server_routes_http_routes_dashboard.ml.
    Contains GET handler logic for /api/v1/agent-activity,
    /api/v1/tool-metrics, /api/v1/agent-timeline. *)

module Http = Http_server_eio


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
    (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
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

(* [utc_offset_min] is signed, unlike the other numeric query values here: a
   viewer west of Greenwich sends a negative one. *)
let signed_int_param ~name ~default = function
  | None -> Ok default
  | Some raw ->
    let negative = String.length raw > 0 && Char.equal raw.[0] '-' in
    let digits = if negative then String.sub raw 1 (String.length raw - 1) else raw in
    (match
       if String.length digits > 0 && String.for_all is_ascii_digit digits
       then int_of_string_opt digits
       else None
     with
     | Some value -> Ok (if negative then -value else value)
     | None -> Error (name ^ " must be an integer"))
;;

(* [GET /api/v1/tool-metrics/series]: hourly or daily totals of the retained
   tool calls, for the charts on the Tools page. *)
let tool_series_default_hours = 24.0
let tool_series_max_tool_name_bytes = 128

(* The cache key trims each value and reads an empty one as absent, while the
   scan filters on the text as sent. A name with surrounding whitespace would
   share a key with another request and match different rows, so such a name is
   refused instead of trimmed. *)
let tool_name_param = function
  | None -> Ok None
  | Some raw ->
    if String.length raw > 0
       && String.length raw <= tool_series_max_tool_name_bytes
       && String.trim raw = raw
    then Ok (Some raw)
    else
      Error
        (Printf.sprintf
           "tool must be 1 to %d bytes with no leading or trailing whitespace"
           tool_series_max_tool_name_bytes)
;;

(* The store keys its rows by the internal tool name, while the charts and the
   models show the public one ([Execute] for [tool_execute]). A filter by a
   public name matched no row and drew an empty series. The filter goes through
   the projection the runtime uses to name a tool, and an internal or unknown
   name stays as sent. *)
let series_tool_filter raw =
  Result.map
    (Option.map Keeper_tool_descriptor_resolution.canonical_tool_name)
    (tool_name_param raw)
;;

type tool_series_request =
  { since_hours : float
  ; width : Tool_metrics_series.width
  ; utc_offset_min : int
  ; tool_name : string option
  }

let tool_series_window request ~until =
  Tool_metrics_series.sliding_window
    ~span_s:(request.since_hours *. Masc_time_constants.hour)
    ~until
    ~width:request.width
    ~utc_offset_min:request.utc_offset_min
;;

(* The window depends on the clock, so a request is checked against the clock
   once here, and the read builds its window again from the clock it runs at.
   The same request gives the same verdict at both times. *)
let tool_series_request req =
  let open Result.Syntax in
  let* since_hours =
    positive_float_param
      ~name:"since_hours"
      ~default:tool_series_default_hours
      (Server_utils.query_param req "since_hours")
  in
  let* width =
    match Server_utils.query_param req "bucket" with
    | None -> Ok Tool_metrics_series.Hour
    | Some raw -> Tool_metrics_series.width_of_string raw
  in
  let* utc_offset_min =
    signed_int_param
      ~name:"utc_offset_min"
      ~default:0
      (Server_utils.query_param req "utc_offset_min")
  in
  let* tool_name = series_tool_filter (Server_utils.query_param req "tool") in
  let request = { since_hours; width; utc_offset_min; tool_name } in
  let* (_ : Tool_metrics_series.window) =
    tool_series_window request ~until:(Time_compat.now ())
  in
  Ok request
;;

exception Tool_series_failed of string

let tool_series_cache_key config request =
  Server_dashboard_http_core_cache.tool_metrics_series_cache_key config
    [ "since_hours", Some (string_of_float request.since_hours)
    ; "bucket", Some (Tool_metrics_series.string_of_width request.width)
    ; "utc_offset_min", Some (string_of_int request.utc_offset_min)
    ; "tool", request.tool_name ]
;;

(* The scan reads up to a month of rows, about a second of CPU, so it runs on
   the executor pool behind the same 30 s cache as the other live rollups.
   A failed read raises, and the cache keeps nothing of it. *)
let tool_series_http_json ~(config : Workspace.config) request : Yojson.Safe.t =
  let cache_key = tool_series_cache_key config request in
  Dashboard_cache.get_or_compute
    cache_key
    ~ttl:Server_dashboard_http_core_cache.live_cache_ttl_s
    (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
       let until = Time_compat.now () in
       match tool_series_window request ~until with
       | Error detail -> raise (Tool_series_failed detail)
       | Ok window ->
         (match
            Tool_metrics_store.read_series
              ~masc_root:(Workspace.masc_dir config)
              ~window
              ?tool_name:request.tool_name
              ()
          with
          | Error detail -> raise (Tool_series_failed detail)
          | Ok series ->
            Tool_metrics_series.to_json
              ~generated_at:until
              ?tool_name:request.tool_name
              ~public_names:
                Keeper_tool_descriptor_resolution.public_names_for_internal
              series)))
;;

let add_agent_api_routes router =
  router
  (* Agent activity -- per-agent tool call stats from telemetry *)
  |> Server_route.get Server_route.Public_read "/api/v1/agent-activity" (fun state req reqd ->
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
       )

  (* Tool metrics -- restart-safe aggregate stats for dashboard *)
  |> Server_route.get Server_route.Public_read "/api/v1/tool-metrics" (fun _state req reqd ->
         let json =
           Tool_unified.summary_report
             ~public_names:
               Keeper_tool_descriptor_resolution.public_names_for_internal
             ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )

  (* Tool call series -- hourly or daily totals for the Tools page charts *)
  |> Server_route.get Server_route.Public_read "/api/v1/tool-metrics/series" (fun state req reqd ->
         match tool_series_request req with
         | Error detail ->
           Http.Response.json_value
             ~status:`Bad_request
             (`Assoc [ "error", `String detail ])
             reqd
         | Ok request ->
           (match
              tool_series_http_json ~config:(Mcp_server.workspace_config state) request
            with
            | json -> Http.Response.json_value ~compress:true ~request:req json reqd
            | exception Tool_series_failed detail ->
              Http.Response.json_value
                ~status:`Internal_server_error
                (`Assoc [ "error", `String detail ])
                reqd)
       )

  (* Agent timeline -- per-agent activity timeline for Observatory detail *)
  |> Server_route.get Server_route.Public_read "/api/v1/agent-timeline" (fun state req reqd ->
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
             let open Result.Syntax in
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
       )
