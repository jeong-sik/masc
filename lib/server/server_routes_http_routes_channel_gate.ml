(** HTTP routes for the Channel Gate.

    Provides [/api/v1/gate/*] endpoints for external channel consumers
    (Discord bots, Telegram bots, etc.) to interact with keepers.

    Mutation endpoints use Bearer token auth via [with_tool_auth]. Public
    monitoring surfaces stay on [with_public_read], but their JSON responses
    only emit CORS headers for same-origin or explicitly allowlisted local
    dev origins.

    @since 2.217.0 *)

open Server_auth
open Server_utils

module Http = Http_server_eio

(** POST /api/v1/gate/message

    Accept an inbound message from an external channel,
    route it to the named keeper, return the response.

    Request body:
    {[
      {
        "channel": "discord",
        "channel_user_id": "123456789",
        "channel_user_name": "user#1234",
        "channel_room_id": "987654321",
        "keeper_name": "luna",
        "content": "What is the project status?",
        "idempotency_key": "discord-msg-abc123",
        "metadata": {}
      }
    ]}

    Response (success):
    {[
      {
        "ok": true,
        "keeper_name": "luna",
        "reply": "The project is on track...",
        "turn_stats": { "model_used": null, "duration_ms": 1234, "tokens_used": 567 }
      }
    ]}

    Response (error):
    {[ { "ok": false, "error": "keeper_name is required" } ]}
*)
(** Map typed gate_error to HTTP status code. *)
let http_status_of_gate_error : Channel_gate.gate_error -> Httpun.Status.t = function
  | Validation (Duplicate_message _) -> `Conflict
  | Validation _ -> `Bad_request
  | Keeper_error _ -> `Bad_gateway
  | Dispatch_unavailable -> `Service_unavailable
  | Internal _ -> `Internal_server_error

let metric_context_of_json json =
  let open Yojson.Safe.Util in
  let field key =
    json |> member key |> to_string_option
    |> Option.value ~default:""
    |> String.trim
  in
  let channel =
    match field "channel" with
    | "" -> "unknown"
    | value -> String.lowercase_ascii (String.trim value)
  in
  (channel, field "channel_room_id", field "keeper_name")

let record_validation_error_metric ~duration_ms body_str message =
  let fallback () =
    Channel_gate_metrics.record_attempt
      ~channel:"unknown"
      ~room_id:""
      ~keeper:""
      ~duration_ms
      (Channel_gate_metrics.Validation_error message)
  in
  try
    let json = Yojson.Safe.from_string body_str in
    let channel, room_id, keeper = metric_context_of_json json in
    Channel_gate_metrics.record_attempt
      ~channel
      ~room_id
      ~keeper
      ~duration_ms
      (Channel_gate_metrics.Validation_error message)
  with
  | Yojson.Json_error _ -> fallback ()

let record_internal_error_metric ~duration_ms body_str exn =
  let fallback () =
    Channel_gate_metrics.record_internal_error_exn
      ~channel:"unknown"
      ~room_id:""
      ~keeper:""
      ~duration_ms exn
  in
  try
    let json = Yojson.Safe.from_string body_str in
    match Channel_gate.inbound_of_json json with
    | Ok msg ->
        Channel_gate_metrics.record_internal_error_exn
          ~channel:msg.channel
          ~room_id:msg.channel_room_id
          ~keeper:msg.keeper_name
          ~duration_ms exn
    | Error _ -> fallback ()
  with
  | Yojson.Json_error _ -> fallback ()

let request_elapsed_ms request_started =
  Keeper_timing.elapsed_duration_ms ~start_time:request_started
    ~end_time:(Unix.gettimeofday ())

let handle_gate_message ~sw ~clock state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let request_started = Unix.gettimeofday () in
    let dispatch =
      Gate_keeper_backend.dispatch
        ~sw ~clock
        ~proc_mgr:state.Mcp_server.proc_mgr
        ~net:state.Mcp_server.net
        ~config:state.Mcp_server.room_config
    in
    let result =
      try
        let json = Yojson.Safe.from_string body_str in
        match Channel_gate.inbound_of_json json with
        | Error e ->
            let duration_ms = request_elapsed_ms request_started in
            record_validation_error_metric ~duration_ms body_str e;
            Error (Channel_gate.Validation Channel_gate.Empty_content, e)
        | Ok msg ->
            (match Channel_gate.handle_inbound ~dispatch msg with
            | Ok out -> Ok out
            | Error gate_err ->
                Error (gate_err, Channel_gate.gate_error_to_string gate_err))
      with
      | Yojson.Json_error _e ->
          let duration_ms = request_elapsed_ms request_started in
          record_validation_error_metric ~duration_ms body_str "invalid json";
          Error (Channel_gate.Validation Channel_gate.Empty_content, "invalid json")
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          (* Log details server-side, return generic message to client *)
          let duration_ms = request_elapsed_ms request_started in
          record_internal_error_metric ~duration_ms body_str exn;
          Log.Misc.error "channel_gate internal error: %s" (Printexc.to_string exn);
          Error (Channel_gate.Internal "", "internal error")
    in
    match result with
    | Ok out ->
        respond_json_with_cors ~status:`OK request reqd
          (Yojson.Safe.to_string (Channel_gate.outbound_to_json out))
    | Error (gate_err, client_msg) ->
        let status = http_status_of_gate_error gate_err in
        respond_json_with_cors ~status request reqd
          (Yojson.Safe.to_string (Channel_gate.error_json client_msg))
  )

(** GET /api/v1/gate/events?channel=<channel>&keeper=<keeper>&room_id=<room>&limit=<n>

    Recent connector event snapshot for dashboard/ops surfaces.
    Returns newest-first gate attempts with optional filters.
    [limit] defaults to 50 and is clamped to [1..Channel_gate_metrics.max_recent_events]. *)
let handle_gate_events _state request reqd =
  let limit =
    int_query_param request "limit" ~default:50
    |> fun value -> max 1 (min Channel_gate_metrics.max_recent_events value)
  in
  let trim_filter key =
    match query_param request key |> Option.map String.trim with
    | Some value when value <> "" -> Some value
    | _ -> None
  in
  let json =
    Channel_gate_metrics.events_json
      ?channel:(trim_filter "channel")
      ?keeper:(trim_filter "keeper")
      ?room_id:(trim_filter "room_id")
      ~limit ()
  in
  respond_public_read_json ~status:`OK request reqd
    (Yojson.Safe.to_string json)

(** GET /api/v1/gate/health

    Simple health check for the gate layer. *)
let handle_gate_health _state request reqd =
  respond_public_read_json ~status:`OK request reqd
    {|{"ok":true,"service":"channel_gate"}|}

(** GET /api/v1/gate/status

    Per-channel connector metrics: message counts, last activity,
    average latency, error counts.  Public read. *)
let handle_gate_status _state request reqd =
  let json = Channel_gate_metrics.snapshot_json () in
  respond_public_read_json ~status:`OK request reqd
    (Yojson.Safe.to_string json)

(** GET /api/v1/gate/connectors

    Generic connector descriptor surface for dashboard/ops consumers.
    The gate advertises which connectors exist and their current runtime
    snapshots without requiring the caller to hardcode vendor-specific
    knowledge.  Delegates to {!Channel_gate_connector.connectors_json}. *)
let handle_gate_connectors _state request reqd =
  let audit_limit =
    int_query_param request "audit_limit" ~default:10
    |> fun value -> max 1 (min 50 value)
  in
  let gate_status = Channel_gate_metrics.snapshot_json () in
  let json =
    Channel_gate_connector.connectors_json ~gate_status_json:gate_status
      ~audit_limit ()
  in
  respond_public_read_json ~status:`OK request reqd
    (Yojson.Safe.to_string json)

(** GET /api/v1/gate/connector/status?name=<connector>&audit_limit=<n>

    Generic connector status. Accepts the current [name=<connector>] form and
    also tolerates legacy [channel=<connector>] callers. *)
let resolve_connector_status_name ?name ?channel () =
  match Option.map String.trim name with
  | Some name when name <> "" -> Some (String.lowercase_ascii name)
  | _ -> (
      match Option.map String.trim channel with
      | Some legacy when legacy <> "" ->
          Some (String.lowercase_ascii legacy)
      | _ -> None)

let handle_gate_connector_status _state request reqd =
  let connector_name =
    resolve_connector_status_name
      ?name:(query_param request "name")
      ?channel:(query_param request "channel")
      ()
  in
  match connector_name with
  | None | Some "" ->
      respond_public_read_json ~status:`Bad_request request reqd
        (Yojson.Safe.to_string
           (Channel_gate.error_json "name or channel is required"))
  | Some name -> (
      match Channel_gate_connector.find name with
      | None ->
          respond_public_read_json ~status:`Not_found request reqd
            (Yojson.Safe.to_string
               (Channel_gate.error_json ("unknown connector: " ^ name)))
      | Some (module C) ->
          let audit_limit =
            int_query_param request "audit_limit" ~default:10
            |> fun value -> max 1 (min 50 value)
          in
          respond_public_read_json ~status:`OK request reqd
            (Yojson.Safe.to_string (C.status_json ~audit_limit ())))

let gate_keeper_ctx ~sw ~clock state =
  {
    Tool_keeper.config = state.Mcp_server.room_config;
    agent_name = "gate:connector";
    sw;
    clock;
    proc_mgr = state.Mcp_server.proc_mgr;
    net = state.Mcp_server.net;
  }

let keeper_exists ~sw ~clock state keeper_name =
  let args = `Assoc [ ("name", `String keeper_name) ] in
  match
    Tool_keeper.dispatch (gate_keeper_ctx ~sw ~clock state)
      ~name:"masc_keeper_status" ~args
  with
  | Some (true, _) -> Ok true
  | Some (false, err) ->
      if String_util.contains_substring
           (String.lowercase_ascii err) "keeper not found"
      then Ok false
      else Error err
  | None -> Error "keeper dispatch unavailable"

let respond_keeper_tool_json ~sw ~clock state request reqd ~tool_name ~args =
  match
    Tool_keeper.dispatch (gate_keeper_ctx ~sw ~clock state) ~name:tool_name ~args
  with
  | Some (true, body) -> (
      try
        ignore (Yojson.Safe.from_string body);
        respond_json_with_cors ~status:`OK request reqd body
      with
      | Yojson.Json_error err ->
          Log.Misc.error "channel_gate %s returned invalid json: %s"
            tool_name err;
          respond_json_with_cors ~status:`Internal_server_error request reqd
            (Yojson.Safe.to_string
               (Channel_gate.error_json "internal error")) )
  | Some (false, err) ->
      let lower = String.lowercase_ascii err in
      let status =
        if String_util.contains_substring lower "keeper not found" then `Not_found
        else `Bad_gateway
      in
      respond_json_with_cors ~status request reqd
        (Yojson.Safe.to_string (Channel_gate.error_json err))
  | None ->
      respond_json_with_cors ~status:`Service_unavailable request reqd
        (Yojson.Safe.to_string
           (Channel_gate.error_json "keeper dispatch unavailable"))

(** GET /api/v1/gate/keepers?limit=100&detailed=true

    Authenticated keeper discovery for channel-side connectors. *)
let handle_gate_keepers ~sw ~clock state request reqd =
  let limit =
    int_query_param request "limit" ~default:100
    |> fun value -> max 1 (min 200 value)
  in
  let detailed = bool_query_param request "detailed" ~default:true in
  let args =
    `Assoc [ ("limit", `Int limit); ("detailed", `Bool detailed) ]
  in
  respond_keeper_tool_json ~sw ~clock state request reqd
    ~tool_name:"masc_keeper_list" ~args

(** GET /api/v1/gate/keeper-status?name=<keeper>

    Authenticated single-keeper status for connector admin surfaces. *)
let handle_gate_keeper_status ~sw ~clock state request reqd =
  match query_param request "name" with
  | Some raw_name ->
      let name = String.trim raw_name in
      if name = "" then
        respond_json_with_cors ~status:`Bad_request request reqd
          (Yojson.Safe.to_string
             (Channel_gate.error_json "name is required"))
      else
        let args = `Assoc [ ("name", `String name) ] in
        respond_keeper_tool_json ~sw ~clock state request reqd
          ~tool_name:"masc_keeper_status" ~args
  | None ->
      respond_json_with_cors ~status:`Bad_request request reqd
        (Yojson.Safe.to_string
           (Channel_gate.error_json "name is required"))

(** Shared bind handler: parse body, validate keeper, dispatch to connector. *)
let handle_bind_for_connector ~sw ~clock state request reqd
    ~(bind_fn :
       channel_id:string ->
       keeper_name:string ->
       actor_name:string ->
       (Yojson.Safe.t, string) result) =
  Http.Request.read_body_async reqd (fun body_str ->
    try
      let json = Yojson.Safe.from_string body_str in
      let channel_id =
        json |> Yojson.Safe.Util.member "channel_id"
        |> Yojson.Safe.Util.to_string_option
        |> Option.value ~default:""
        |> String.trim
      in
      let keeper_name =
        json |> Yojson.Safe.Util.member "keeper_name"
        |> Yojson.Safe.Util.to_string_option
        |> Option.value ~default:""
        |> String.trim
      in
      if channel_id = "" then
        respond_json_with_cors ~status:`Bad_request request reqd
          (Yojson.Safe.to_string
             (Channel_gate.error_json "channel_id is required"))
      else if keeper_name = "" then
        respond_json_with_cors ~status:`Bad_request request reqd
          (Yojson.Safe.to_string
             (Channel_gate.error_json "keeper_name is required"))
      else
        match keeper_exists ~sw ~clock state keeper_name with
        | Error err ->
            respond_json_with_cors ~status:`Service_unavailable request reqd
              (Yojson.Safe.to_string (Channel_gate.error_json err))
        | Ok false ->
            respond_json_with_cors ~status:`Not_found request reqd
              (Yojson.Safe.to_string
                 (Channel_gate.error_json ("unknown keeper: " ^ keeper_name)))
        | Ok true -> (
            let actor_name =
              sanitized_dashboard_actor_for_request
                ~base_path:state.Mcp_server.room_config.base_path request
              |> Option.value ~default:"dashboard"
              |> String.trim
            in
            match bind_fn ~channel_id ~keeper_name ~actor_name with
            | Ok payload ->
                respond_json_with_cors ~status:`OK request reqd
                  (Yojson.Safe.to_string payload)
            | Error err ->
                respond_json_with_cors ~status:`Internal_server_error request
                  reqd
                  (Yojson.Safe.to_string (Channel_gate.error_json err)))
    with Yojson.Json_error _ ->
      respond_json_with_cors ~status:`Bad_request request reqd
        (Yojson.Safe.to_string (Channel_gate.error_json "invalid json")))

(** Shared unbind handler: parse body, dispatch to connector. *)
let handle_unbind_for_connector state request reqd
    ~(unbind_fn :
       channel_id:string ->
       actor_name:string ->
       (Yojson.Safe.t, string) result) =
  Http.Request.read_body_async reqd (fun body_str ->
    try
      let json = Yojson.Safe.from_string body_str in
      let channel_id =
        json |> Yojson.Safe.Util.member "channel_id"
        |> Yojson.Safe.Util.to_string_option
        |> Option.value ~default:""
        |> String.trim
      in
      if channel_id = "" then
        respond_json_with_cors ~status:`Bad_request request reqd
          (Yojson.Safe.to_string
             (Channel_gate.error_json "channel_id is required"))
      else
        let actor_name =
          sanitized_dashboard_actor_for_request
            ~base_path:state.Mcp_server.room_config.base_path request
          |> Option.value ~default:"dashboard"
          |> String.trim
        in
        match unbind_fn ~channel_id ~actor_name with
        | Ok payload ->
            respond_json_with_cors ~status:`OK request reqd
              (Yojson.Safe.to_string payload)
        | Error "binding not found" ->
            respond_json_with_cors ~status:`Not_found request reqd
              (Yojson.Safe.to_string
                 (Channel_gate.error_json "binding not found"))
        | Error err ->
            respond_json_with_cors ~status:`Internal_server_error request reqd
              (Yojson.Safe.to_string (Channel_gate.error_json err))
    with Yojson.Json_error _ ->
      respond_json_with_cors ~status:`Bad_request request reqd
        (Yojson.Safe.to_string (Channel_gate.error_json "invalid json")))

(** POST /api/v1/gate/connector/bind?name=<connector>

    Generic connector bind.  Dispatches to the registered connector's
    [bind] function.  Validates keeper existence before binding. *)
let handle_gate_connector_bind ~sw ~clock state request reqd =
  let connector_name =
    query_param request "name"
    |> Option.map String.trim
    |> Option.value ~default:""
  in
  if connector_name = "" then
    respond_json_with_cors ~status:`Bad_request request reqd
      (Yojson.Safe.to_string (Channel_gate.error_json "name is required"))
  else
    match Channel_gate_connector.find connector_name with
    | None ->
        respond_json_with_cors ~status:`Not_found request reqd
          (Yojson.Safe.to_string
             (Channel_gate.error_json
                ("unknown connector: " ^ connector_name)))
    | Some (module C) ->
        handle_bind_for_connector ~sw ~clock state request reqd
          ~bind_fn:C.bind

(** POST /api/v1/gate/connector/unbind?name=<connector>

    Generic connector unbind. *)
let handle_gate_connector_unbind _state request reqd =
  let connector_name =
    query_param request "name"
    |> Option.map String.trim
    |> Option.value ~default:""
  in
  if connector_name = "" then
    respond_json_with_cors ~status:`Bad_request request reqd
      (Yojson.Safe.to_string (Channel_gate.error_json "name is required"))
  else
    match Channel_gate_connector.find connector_name with
    | None ->
        respond_json_with_cors ~status:`Not_found request reqd
          (Yojson.Safe.to_string
             (Channel_gate.error_json
                ("unknown connector: " ^ connector_name)))
    | Some (module C) ->
        handle_unbind_for_connector _state request reqd
          ~unbind_fn:C.unbind

(** Register all gate routes on the router. *)
let add_routes ~sw ~clock router =
  router
  |> Http.Router.post "/api/v1/gate/message" (fun request reqd ->
       with_tool_auth ~tool_name:"channel_gate" (fun state _req reqd ->
         handle_gate_message ~sw ~clock state request reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/gate/health" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_gate_health state request reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/gate/status" (fun request reqd ->
        with_public_read (fun state _req reqd ->
          handle_gate_status state request reqd
        ) request reqd)

  |> Http.Router.get "/api/v1/gate/connectors" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_gate_connectors state request reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/gate/connector/status" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_gate_connector_status state request reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/gate/events" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_gate_events state request reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/gate/keepers" (fun request reqd ->
        with_tool_auth ~tool_name:"channel_gate" (fun state _req reqd ->
         handle_gate_keepers ~sw ~clock state request reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/gate/keeper-status" (fun request reqd ->
       with_tool_auth ~tool_name:"channel_gate" (fun state _req reqd ->
         handle_gate_keeper_status ~sw ~clock state request reqd
       ) request reqd)

  (* Generic connector routes — dispatch by ?name=<connector> *)
  |> Http.Router.post "/api/v1/gate/connector/bind" (fun request reqd ->
       with_tool_auth ~tool_name:"channel_gate" (fun state _req reqd ->
         handle_gate_connector_bind ~sw ~clock state request reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/gate/connector/unbind" (fun request reqd ->
       with_tool_auth ~tool_name:"channel_gate" (fun _state _req reqd ->
         handle_gate_connector_unbind _state request reqd
       ) request reqd)
