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

type cp_snapshot_cache = {
  snapshot : Yojson.Safe.t;
  cached_at : float;
}

let _cp_snapshot_cache : cp_snapshot_cache ref =
  ref
    {
      snapshot =
        `Assoc [("generated_at", `String (Types.now_iso ())); ("status", `String "initializing")];
      cached_at = 0.0;
    }

let cached_cp_snapshot_opt () =
  let cache = !_cp_snapshot_cache in
  if cache.cached_at > 0.0 then
    Some cache.snapshot
  else
    None

let compute_cp_summary ~state =
  let config = state.Mcp_server.room_config in
  let t0 = Time_compat.now () in
  (* Build full snapshot once to share filesystem reads between summary
     and swarm-status.  Previously Swarm_status.build_json re-read
     operations/detachments/alerts/decisions/traces from disk, doubling
     total I/O and causing the 60s timeout to trip ~58x/day (#5091). *)
  let snapshot = Command_plane_v2.snapshot_json config in
  let dt_snapshot = Time_compat.now () -. t0 in
  let summary = Command_plane_v2.summary_json config in
  let dt_summary = Time_compat.now () -. t0 -. dt_snapshot in
  let swarm_status =
    if Room.is_initialized config then
      Swarm_status.build_json_from_snapshot ~timeline_limit_override:6 config snapshot
    else Swarm_status.empty_json
  in
  let dt_total = Time_compat.now () -. t0 in
  if dt_total >= 5.0 then
    Log.CmdPlane.info
      "cp-summary compute breakdown: snapshot=%.1fs summary=%.1fs total=%.1fs"
      dt_snapshot dt_summary dt_total;
  assoc_add "swarm_status" swarm_status summary

let start_cp_summary_refresh_loop ~state ~sw ~clock =
  Proactive_refresh.start ~sw ~clock
    ~config:{ (Proactive_refresh.default_config
                 ~label:"cp-summary"
                 ~interval_s:_cp_summary_refresh_interval_s)
              with timeout_s = 90.0;
                   max_backoff_s = 300.0;
                   warm_delay_s = 30.0 }
    ~compute:(fun () -> compute_cp_summary ~state)
    ~on_result:(fun json -> _cp_summary_ref := json)

let command_plane_summary_http_json ~state:_ =
  (* Always return the proactively cached ref.  Never compute synchronously —
     compute_cp_summary can hang when Swarm_status.build_json blocks on
     filesystem I/O, causing namespace-truth and /command-plane/summary to time out.
     The background refresh loop populates the ref within one interval (120s). *)
  !_cp_summary_ref

(* --- Command-plane snapshot proactive cache ---
   This endpoint preserves the full public snapshot contract, so refreshes can
   legitimately take much longer than the dashboard-friendly summary surfaces.
   Use a slower cadence and larger timeout to avoid constant timeout/backoff
   churn while still keeping a warm cached snapshot available. *)

let _cp_snapshot_compute_mu = Eio.Mutex.create ()
let _cp_snapshot_refresh_interval_s = 120.0
let _cp_snapshot_timeout_s = 60.0

let compute_cp_snapshot ~state =
  let config = state.Mcp_server.room_config in
  let snapshot = Command_plane_v2.snapshot_json config in
  let swarm_status =
    if Room.is_initialized config then
      Swarm_status.build_json_from_snapshot config snapshot
    else Swarm_status.empty_json
  in
  assoc_add "swarm_status" swarm_status snapshot

let current_cp_snapshot_cache () = !_cp_snapshot_cache
let current_cp_snapshot () = (current_cp_snapshot_cache ()).snapshot

let store_cp_snapshot snapshot =
  _cp_snapshot_cache := { snapshot; cached_at = Time_compat.now () }

let fresh_cp_snapshot_opt () =
  let cache = current_cp_snapshot_cache () in
  if cache.cached_at <= 0.0 then
    None
  else if
    Time_compat.now () -. cache.cached_at
    < Env_config_governance.Dashboard_config.command_plane_snapshot_cache_ttl_s ()
  then
    Some cache.snapshot
  else
    None

let start_cp_snapshot_refresh_loop ~state ~sw ~clock =
  if not (Env_config_governance.Dashboard_config.command_plane_snapshot_refresh_enabled ())
  then
    Log.CmdPlane.info
      "cp-snapshot proactive refresh disabled (set MASC_COMMAND_PLANE_SNAPSHOT_REFRESH_ENABLED=1 to enable)"
  else
    Proactive_refresh.start ~sw ~clock
      ~config:{ (Proactive_refresh.default_config
                   ~label:"cp-snapshot"
                   ~interval_s:_cp_snapshot_refresh_interval_s)
                with timeout_s = _cp_snapshot_timeout_s;
                     warm_delay_s = 90.0 }
      ~compute:(fun () -> compute_cp_snapshot ~state)
      ~on_result:store_cp_snapshot

let cp_snapshot_runtime_clock state =
  match state.Mcp_server.clock with
  | Some clock -> clock
  | None -> Eio_context.get_clock ()

let cp_snapshot_fallback_json ~status ~error ~message =
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("status", `String status);
      ("error", `String error);
      ("message", `String message);
    ]

let command_plane_snapshot_http_json ~state =
  if Env_config_governance.Dashboard_config.command_plane_snapshot_refresh_enabled ()
  then
    current_cp_snapshot ()
  else
    match fresh_cp_snapshot_opt () with
    | Some snapshot -> snapshot
    | None ->
        Eio.Mutex.use_rw ~protect:true _cp_snapshot_compute_mu (fun () ->
          if Env_config_governance.Dashboard_config.command_plane_snapshot_refresh_enabled ()
          then
            current_cp_snapshot ()
          else
            match fresh_cp_snapshot_opt () with
            | Some snapshot -> snapshot
            | None ->
                let started_at = Time_compat.now () in
                try
                  let snapshot =
                    Eio.Time.with_timeout_exn (cp_snapshot_runtime_clock state)
                      _cp_snapshot_timeout_s (fun () -> compute_cp_snapshot ~state)
                  in
                  let elapsed = Time_compat.now () -. started_at in
                  if elapsed >= 1.0 then
                    Log.CmdPlane.info "cp-snapshot computed on demand (%.1fs)" elapsed;
                  store_cp_snapshot snapshot;
                  snapshot
                with
                | Eio.Time.Timeout ->
                    let elapsed = Time_compat.now () -. started_at in
                    Log.CmdPlane.warn
                      "cp-snapshot on-demand compute timed out (%.1fs)" elapsed;
                    (match fresh_cp_snapshot_opt () with
                     | Some snapshot -> snapshot
                     | None ->
                         cp_snapshot_fallback_json ~status:"timeout"
                           ~error:"command_plane_snapshot_timeout"
                           ~message:
                             "Command-plane snapshot timed out; enable proactive snapshot refresh or retry later.")
                | exn ->
                    let elapsed = Time_compat.now () -. started_at in
                    Log.CmdPlane.warn
                      "cp-snapshot on-demand compute failed (%.1fs): %s"
                      elapsed (Printexc.to_string exn);
                    (match fresh_cp_snapshot_opt () with
                     | Some snapshot -> snapshot
                     | None ->
                         cp_snapshot_fallback_json ~status:"unavailable"
                           ~error:"command_plane_snapshot_unavailable"
                           ~message:
                             "Command-plane snapshot is unavailable; enable proactive snapshot refresh or retry later."))

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
      net = state.Mcp_server.net;
      mcp_session_id = deps.get_session_id_any request;
    }
  in
  let clock = deps.get_clock () in
  let full =
    match Eio.Time.with_timeout clock 30.0 (fun () ->
      Ok (Command_plane_orchestra.json ?run_id ?operation_id ctx)
    ) with
    | Ok v -> v
    | Error `Timeout ->
        `Assoc [
          ("error", `String "timeout");
          ("message", `String "Orchestra computation timed out after 30s");
          ("generated_at", `String (Types.now_iso ()));
        ]
  in
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
