(** HTTP routes for the Channel Gate.

    Provides [/api/v1/gate/*] endpoints for external channel consumers
    (Discord bots, Telegram bots, etc.) to interact with keepers.

    All Channel Gate API endpoints use Bearer token auth via [with_tool_auth],
    except [/api/v1/gate/health], which is public and uses [with_public_read].

    @since 2.217.0 *)

open Server_auth

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
        "turn_stats": { "model_used": "...", "duration_ms": 1234, "tokens_used": 567 }
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

let handle_gate_message ~sw ~clock state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let result =
      try
        let json = Yojson.Safe.from_string body_str in
        match Channel_gate.inbound_of_json json with
        | Error e -> Error (Channel_gate.Validation Channel_gate.Empty_content, e)
        | Ok msg ->
            (match Channel_gate.handle_inbound
              ~sw ~clock
              ~proc_mgr:(state.Mcp_server.proc_mgr)
              ~net:(state.Mcp_server.net)
              ~config:state.Mcp_server.room_config
              msg
            with
            | Ok out -> Ok out
            | Error gate_err ->
                Error (gate_err, Channel_gate.gate_error_to_string gate_err))
      with
      | Yojson.Json_error _e ->
          Error (Channel_gate.Validation Channel_gate.Empty_content, "invalid json")
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          (* Log details server-side, return generic message to client *)
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

(** GET /api/v1/gate/events?channel=<channel>&keeper=<keeper>

    SSE event stream.  The consumer opens a long-lived connection
    and receives keeper events (board posts, broadcasts, lifecycle)
    filtered by channel and optionally by keeper name.

    Uses [Sse.subscribe_external] -- the same proven mechanism
    used by gRPC and WebSocket transports. *)
(* SSE events endpoint (GET /api/v1/gate/events) will be implemented
   in Phase 3, building on the existing Sse.subscribe_external mechanism
   used by gRPC and WebSocket transports.  For now, consumers poll
   POST /api/v1/gate/message for request/response interaction. *)

(** GET /api/v1/gate/health

    Simple health check for the gate layer. *)
let handle_gate_health _state request reqd =
  respond_json_with_cors ~status:`OK request reqd
    {|{"ok":true,"service":"channel_gate"}|}

(** GET /api/v1/gate/status

    Per-channel connector metrics: message counts, last activity,
    average latency, error counts.  Public read. *)
let handle_gate_status _state request reqd =
  let json = Channel_gate_metrics.snapshot_json () in
  respond_json_with_cors ~status:`OK request reqd
    (Yojson.Safe.to_string json)

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
