type deps = {
  query_param : Httpun.Request.t -> string -> string option;
  int_query_param : Httpun.Request.t -> string -> default:int -> int;
  operator_actor_hint : Httpun.Request.t -> string option;
  get_session_id_any : Httpun.Request.t -> string option;
  auth_token_from_request : Httpun.Request.t -> string option;
  get_switch : unit -> Eio.Switch.t;
  get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t;
  get_net : unit -> [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
}

let assoc_add key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | json -> `Assoc [ ("payload", json); (key, value) ]

let command_plane_actor deps request =
  Option.value ~default:"dashboard" (deps.operator_actor_hint request)

let command_plane_tool_ctx ~deps ~state request :
    (_, _) Tool_command_plane.context =
  {
    config = state.Mcp_server.room_config;
    agent_name = command_plane_actor deps request;
    sw = Some (deps.get_switch ());
    clock = Some (deps.get_clock ());
    net = Some (deps.get_net ());
    mcp_state = Some state;
    mcp_session_id = deps.get_session_id_any request;
    auth_token = deps.auth_token_from_request request;
  }

let tool_command_plane_http_json ~deps ~state request ~name ~args =
  match
    Tool_command_plane.dispatch
      (command_plane_tool_ctx ~deps ~state request)
      ~name ~args
  with
  | Some (true, payload) -> (
      try Ok (Yojson.Safe.from_string payload)
      with Yojson.Json_error message -> Error ("invalid tool json: " ^ message))
  | Some (false, payload) -> (
      try
        match Yojson.Safe.from_string payload with
        | `Assoc fields -> (
            match List.assoc_opt "message" fields with
            | Some (`String message) -> Error message
            | _ -> Error payload)
        | _ -> Error payload
      with Yojson.Json_error _ -> Error payload)
  | None -> Error ("unsupported command-plane tool: " ^ name)

(* --- Command-plane summary proactive cache ---
   Background refresh via start_cp_summary_refresh_loop.
   The HTTP handler returns the cached ref immediately (0ms). *)

let _cp_summary_ref : Yojson.Safe.t ref =
  ref (`Assoc [("generated_at", `String (Types.now_iso ())); ("status", `String "initializing")])

let _cp_summary_refresh_interval_s = 120.0

let compute_cp_summary ~state =
  let config = state.Mcp_server.room_config in
  let summary = Command_plane_v2.summary_json config in
  let swarm_status =
    if Room.is_initialized config then
      Swarm_status.build_json ~timeline_limit_override:6 config
    else Swarm_status.empty_json
  in
  assoc_add "swarm_status" swarm_status summary

let start_cp_summary_refresh_loop ~state ~sw ~clock =
  Eio.Fiber.fork ~sw (fun () ->
    Log.CmdPlane.info "starting cp-summary proactive refresh loop";
    let rec loop () =
      let t0 = Time_compat.now () in
      (try
        _cp_summary_ref := compute_cp_summary ~state;
        let dt = Time_compat.now () -. t0 in
        Log.CmdPlane.info "cp-summary refreshed (%.1fs)" dt
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        let dt = Time_compat.now () -. t0 in
        Log.CmdPlane.warn "cp-summary refresh failed (%.1fs): %s"
          dt (Printexc.to_string exn));
      Eio.Time.sleep clock _cp_summary_refresh_interval_s;
      loop ()
    in
    loop ())

let command_plane_summary_http_json ~state:_ =
  (* Always return the proactively cached ref.  Never compute synchronously —
     compute_cp_summary can hang when Swarm_status.build_json blocks on
     filesystem I/O, causing room-truth and /command-plane/summary to time out.
     The background refresh loop populates the ref within one interval (120s). *)
  !_cp_summary_ref

(* --- Command-plane snapshot proactive cache ---
   Same pattern as the summary cache above, but with a shorter interval (5s)
   because SSE clients poll this endpoint.  Without caching, N concurrent SSE
   connections each trigger a full build_snapshot_state + JSON serialization,
   turning a single ~200ms computation into N * 200ms of redundant I/O. *)

let _cp_snapshot_ref : Yojson.Safe.t ref =
  ref (`Assoc [("generated_at", `String (Types.now_iso ())); ("status", `String "initializing")])

let _cp_snapshot_refresh_interval_s = 5.0

let compute_cp_snapshot ~state =
  let config = state.Mcp_server.room_config in
  let snapshot = Command_plane_v2.snapshot_json config in
  let swarm_status =
    if Room.is_initialized config then
      Swarm_status.build_json_from_snapshot config snapshot
    else Swarm_status.empty_json
  in
  assoc_add "swarm_status" swarm_status snapshot

let start_cp_snapshot_refresh_loop ~state ~sw ~clock =
  Proactive_refresh.start ~sw ~clock
    ~config:{ (Proactive_refresh.default_config
                 ~label:"cp-snapshot"
                 ~interval_s:_cp_snapshot_refresh_interval_s)
              with timeout_s = 10.0 }
    ~compute:(fun () -> compute_cp_snapshot ~state)
    ~on_result:(fun snapshot -> _cp_snapshot_ref := snapshot)

let command_plane_snapshot_http_json ~state:_ =
  !_cp_snapshot_ref

let command_plane_topology_http_json ~state =
  Command_plane_v2.topology_json state.Mcp_server.room_config

let command_plane_units_http_json ~state =
  Command_plane_v2.list_units_json state.Mcp_server.room_config

let command_plane_operations_http_json ~deps ~state request =
  let operation_id = deps.query_param request "operation_id" in
  Command_plane_v2.operation_status_json state.Mcp_server.room_config ?operation_id ()

let command_plane_detachments_http_json ~deps ~state request =
  let operation_id = deps.query_param request "operation_id" in
  let detachment_id = deps.query_param request "detachment_id" in
  Command_plane_v2.list_detachments_json state.Mcp_server.room_config ?operation_id
    ?detachment_id

let command_plane_detachment_status_http_json ~deps ~state request =
  let args =
    `Assoc
      [
        ( "detachment_id",
          match deps.query_param request "detachment_id" with
          | Some value -> `String value
          | None -> `Null );
      ]
  in
  Command_plane_v2.detachment_status_json state.Mcp_server.room_config args

let command_plane_decisions_http_json ~deps ~state request =
  let decision_id = deps.query_param request "decision_id" in
  Command_plane_v2.list_policy_decisions_json state.Mcp_server.room_config
    ?decision_id

let command_plane_capacity_http_json ~state =
  Command_plane_v2.capacity_json state.Mcp_server.room_config

let command_plane_alerts_http_json ~state =
  Command_plane_v2.list_alerts_json state.Mcp_server.room_config

let command_plane_traces_http_json ~deps ~state request =
  let operation_id = deps.query_param request "operation_id" in
  let limit =
    deps.int_query_param request "limit" ~default:25 |> fun v -> max 1 (min 200 v)
  in
  Command_plane_v2.list_traces_json state.Mcp_server.room_config ?operation_id
    ~limit ()

let command_plane_swarm_http_json ~deps:_ ~state:_ _request =
  `Assoc []

let command_plane_orchestra_http_json ~deps ~state request =
  let actor = command_plane_actor deps request in
  let run_id = deps.query_param request "run_id" in
  let operation_id = deps.query_param request "operation_id" in
  let summary_only = deps.query_param request "summary_only" = Some "true" in
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = actor;
      sw = deps.get_switch ();
      clock = deps.get_clock ();
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = deps.get_session_id_any request;
    }
  in
  let full = Command_plane_orchestra.json ?run_id ?operation_id ctx in
  if summary_only then
    (* Strip heavy nodes/edges for lightweight summary response *)
    match full with
    | `Assoc fields ->
        `Assoc (List.filter_map (fun (k, v) ->
          match k with
          | "nodes" | "edges" | "truth_notes" -> None
          | _ -> Some (k, v)
        ) fields)
    | other -> other
  else full

let command_plane_unit_define_http_json ~deps ~state request ~args =
  Command_plane_v2.unit_update_json state.Mcp_server.room_config
    ~actor:(command_plane_actor deps request) args

let command_plane_operation_start_http_json ~deps ~state request ~args =
  tool_command_plane_http_json ~deps ~state request ~name:"masc_operation_start"
    ~args

let command_plane_chain_summary_http_json ~deps ~state request =
  tool_command_plane_http_json ~deps ~state request ~name:"masc_chain_snapshot"
    ~args:(`Assoc [])

let command_plane_chain_run_http_json ~deps ~state request run_id =
  tool_command_plane_http_json ~deps ~state request ~name:"masc_chain_run_get"
    ~args:(`Assoc [ ("run_id", `String run_id) ])

let chain_http_error_status message =
  let starts_with ~prefix value =
    let prefix_len = String.length prefix in
    String.length value >= prefix_len
    && String.equal (String.sub value 0 prefix_len) prefix
  in
  if starts_with ~prefix:"invalid chain run_id:" message then
    `Bad_request
  else if starts_with ~prefix:"chain run not found:" message then
    `Not_found
  else
    `Bad_gateway

