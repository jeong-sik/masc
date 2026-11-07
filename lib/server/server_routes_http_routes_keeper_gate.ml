(* server_routes_http_routes_keeper_gate — HTTP routes for the Keeper Gate
   dashboard surface.

   The gate projection reads, the gate mode settings (workspace, keeper and
   external), the per-keeper exact-lane preference, and the resolve, retry and
   rule-delete actions. Server_routes_http_routes_dashboard.add_routes
   registers this group in the middle of its own pipeline. *)

open Server_auth
open Server_dashboard_http

module Http = Http_server_eio

type gate_mode_recovery =
  | Recovery_completed of Keeper_gate.operator_recovery_report
  | Recovery_failed of string
  | Recovery_not_requested

let gate_mode_change_json change recovery =
  let ( recovery_status
      , recovery_error
      , started
      , queued
      , recovery_failures
      , recovery_blockers )
    =
    match recovery with
    | Recovery_completed report ->
      ( (if report.failures = [] then "completed" else "partial")
      , `Null
      , List.length report.started_ids
      , report.queued
      , report.failures
      , report.blockers )
    | Recovery_failed detail -> "failed", `String detail, 0, 0, [], []
    | Recovery_not_requested -> "not_requested", `Null, 0, 0, [], []
  in
  (* The typed drain blocker is rendered only here, at the wire boundary:
     a closed [kind], the approval ids it names, and the start-failure
     reason when there is one. *)
  let recovery_blockers_json =
    `List
      (List.map
         (fun (owner_blocker : Keeper_gate.auto_judge_owner_blocker) ->
            let kind, approval_ids, reason =
              match owner_blocker.blocker with
              | Keeper_gate.Drain_owner_at_capacity active_ids ->
                "owner_at_capacity", active_ids, `Null
              | Keeper_gate.Drain_entry_changed approval_id ->
                "entry_changed", [ approval_id ], `Null
              | Keeper_gate.Drain_entry_missing approval_id ->
                "entry_missing", [ approval_id ], `Null
              | Keeper_gate.Drain_start_failed (approval_id, detail) ->
                "start_failed", [ approval_id ], `String detail
              | Keeper_gate.Drain_mode_manual -> "mode_manual", [], `Null
              | Keeper_gate.Drain_mode_always_allow ->
                "mode_always_allow", [], `Null
            in
            `Assoc
              [ "keeper_name", `String owner_blocker.keeper_name
              ; "kind", `String kind
              ; ( "approval_ids"
                , `List (List.map (fun id -> `String id) approval_ids) )
              ; "reason", reason
              ])
         recovery_blockers)
  in
  let recovery_failures_json =
    `List
      (List.map
         (fun (failure : Keeper_gate.auto_judge_owner_failure) ->
            `Assoc
              [ "keeper_name", `String failure.keeper_name
              ; ( "approval_id"
                , match failure.approval_id with
                  | Some approval_id -> `String approval_id
                  | None -> `Null )
              ; "operator_detail", `String failure.operator_detail
              ])
         recovery_failures)
  in
  let `Assoc fields = Keeper_gate_mode.change_json change in
  `Assoc
    (("recovery_status", `String recovery_status)
     :: ("recovery_error", recovery_error)
     :: ("started", `Int started)
     :: ("queued", `Int queued)
     :: ("recovery_failure_count", `Int (List.length recovery_failures))
     :: ("recovery_failures", recovery_failures_json)
     :: ("recovery_blockers", recovery_blockers_json)
     :: fields)
;;

(* Which admitted slot this Keeper uses first in one exact-output lane. Naming
   a slot the lane does not offer is refused here rather than on the next run,
   so the operator learns while still looking at the setting. *)
let handle_keeper_exact_lane_body state operator_name request reqd body_str =
  let refuse message =
    respond_json_value_with_cors ~status:`Bad_request request reqd
      (operator_error_json message)
  in
  try
    let fields =
      match Yojson.Safe.from_string body_str with
      | `Assoc fields -> fields
      | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
        []
    in
    match List.assoc_opt "keeper_name" fields, List.assoc_opt "lane_id" fields with
    | ( Some (`String keeper_name)
      , Some (`String lane_id) )
      when String.trim keeper_name <> "" && String.trim lane_id <> "" -> (
      match
        match List.assoc_opt "slot_id" fields with
        | None | Some `Null -> Ok None
        | Some (`String slot_id) when String.trim slot_id <> "" ->
          Ok (Some (String.trim slot_id))
        | Some _ -> Error "slot_id must be a non-empty string or null"
      with
      | Error message -> refuse message
      | Ok slot_id -> (
        let config = Mcp_server.workspace_config state in
        let set () =
          Keeper_exact_lane_preference.set
            config ~actor:operator_name ~keeper_name ~lane_id slot_id
        in
        match
          match slot_id with
          | None -> set ()
          | Some slot_id ->
            Result.bind
              (Keeper_exact_lane_preference.validate_admitted_slot
                 ~lane_id
                 ~slot_id)
              set
        with
        | Error message -> refuse message
        | Ok current ->
          Server_dashboard_http.invalidate_gate_snapshots ~base_path:config.base_path;
          Sse.broadcast
            (`Assoc
               [ "type", `String "keeper_exact_lane_preference_changed"
               ; "keeper_name", `String keeper_name
               ; "lane_id", `String lane_id
               ; ( "slot_id"
                 , match slot_id with
                   | Some slot_id -> `String slot_id
                   | None -> `Null )
               ]);
          respond_json_value_with_cors request reqd
            (`Assoc
               [ "ok", `Bool true
               ; "keeper_name", `String keeper_name
               ; "lane_id", `String lane_id
               ; ( "slot_id"
                 , match current with
                   | Some current ->
                     `String current.Keeper_exact_lane_preference.slot_id
                   | None -> `Null )
               ])))
    | _, _ -> refuse "keeper_name and lane_id are required"
  with Yojson.Json_error message -> refuse message
;;

(* One keeper held to a higher bar than the workspace. Its own handler
   rather than a field on the workspace one: the two answer different
   questions, and a body that omitted [keeper_name] would otherwise move
   every keeper at once. *)
let handle_gate_keeper_mode_body state operator_name request reqd body_str =
  let refuse message =
    respond_json_value_with_cors ~status:`Bad_request request reqd
      (operator_error_json message)
  in
  try
    let fields =
      match Yojson.Safe.from_string body_str with
      | `Assoc fields -> fields
      | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
        []
    in
    match List.assoc_opt "keeper_name" fields with
    | Some (`String keeper_name) when String.trim keeper_name <> "" -> (
      (* An absent mode clears the override; a present one has to parse.
         Absent and unreadable are different answers and only one of them is
         a request to stop singling this keeper out. *)
      match
        match List.assoc_opt "mode" fields with
        | None | Some `Null -> Ok None
        | Some mode_json ->
          Result.map Option.some (Keeper_gate_mode.parse_json mode_json)
      with
      | Error message -> refuse message
      | Ok mode -> (
        (* Same admission bar as the workspace lane: an auto_judge override
           is a promise that a judge topology exists to drain it, and this
           route is the entry point of the override-only-auto_judge state
           the sweeps now serve. *)
        let readiness =
          match mode with
          | Some Keeper_gate_mode.Auto_judge ->
            Hitl_summary_worker.snapshot_topology_readiness ()
          | Some (Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow)
          | None -> Ok ()
        in
        match readiness with
        | Error detail ->
          respond_json_value_with_cors
            ~status:`Service_unavailable
            request
            reqd
            (operator_error_json ("Auto Judge unavailable: " ^ detail))
        | Ok () -> (
        let config = Mcp_server.workspace_config state in
        match
          Keeper_gate_mode.set_for_keeper config ~actor:operator_name
            ~keeper_name mode
        with
        | Error message -> refuse message
        | Ok change ->
          Server_dashboard_http.invalidate_gate_snapshots ~base_path:config.base_path;
          Sse.broadcast
            (`Assoc
               [ "type", `String "gate_keeper_mode_changed"
               ; "keeper_name", `String keeper_name
               ; ( "mode"
                 , match mode with
                   | Some mode -> `String (Keeper_gate_mode.to_string mode)
                   | None -> `Null )
               ]);
          respond_json_value_with_cors request reqd
            (match Keeper_gate_mode.keeper_change_json change with
             | `Assoc fields -> `Assoc fields))))
    | Some _ | None -> refuse "keeper_name is required"
  with Yojson.Json_error message -> refuse message
;;


let handle_gate_mode_body_for_lane
      ~set_mode
      ~sse_type
      state
      operator_name
      request
      reqd
      body_str
  =
  try
    let args = Yojson.Safe.from_string body_str in
    let mode_json =
      match args with
      | `Assoc fields -> List.assoc_opt "mode" fields
      | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
        None
    in
    match mode_json with
    | None ->
      respond_json_value_with_cors
        ~status:`Bad_request
        request
        reqd
        (operator_error_json "mode is required")
    | Some mode_json ->
      (match Keeper_gate_mode.parse_json mode_json with
       | Error message ->
         respond_json_value_with_cors
           ~status:`Bad_request
           request
           reqd
           (operator_error_json message)
       | Ok mode ->
         let config = Mcp_server.workspace_config state in
         let readiness =
           match mode with
           | Keeper_gate_mode.Auto_judge ->
             Hitl_summary_worker.snapshot_topology_readiness ()
           | Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow -> Ok ()
         in
         (match readiness with
          | Error detail ->
            respond_json_value_with_cors
              ~status:`Service_unavailable
              request
              reqd
              (operator_error_json ("Auto Judge unavailable: " ^ detail))
          | Ok () ->
         (match set_mode config ~actor:operator_name mode with
          | Error message ->
            respond_json_value_with_cors
              ~status:`Bad_request
              request
              reqd
              (operator_error_json message)
          | Ok (change : Keeper_gate_mode.change) ->
            Server_dashboard_http.invalidate_gate_snapshots ~base_path:config.base_path;
            Sse.broadcast
              (`Assoc
                 [ "type", `String sse_type
                 ; "mode", `String (Keeper_gate_mode.to_string mode)
                 ; ( "previous_mode"
                   , match change.previous with
                     | Some previous -> `String (Keeper_gate_mode.to_string previous)
                     | None -> `Null )
                 ; "actor", `String operator_name
                 ; "changed_at", `String change.changed_at
                 ]);
            let recovery =
              match mode with
              | Keeper_gate_mode.Auto_judge ->
                (match
                   Keeper_gate.request_operator_auto_judge_recovery
                     ~base_path:config.base_path
                 with
                 | Ok report -> Recovery_completed report
                 | Error detail ->
                   Log.Dashboard.emit
                     Log.Warn
                     ~details:
                       (`Assoc
                          [ "event", `String "gate_mode_recovery_failed"
                          ; "base_path", `String config.base_path
                          ; "actor", `String operator_name
                          ; "mode", `String (Keeper_gate_mode.to_string mode)
                          ; "changed_at", `String change.changed_at
                          ; "error", `String detail
                          ])
                     "Gate mode was saved, but Auto Judge recovery failed";
                   Recovery_failed detail)
              | Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow ->
                Recovery_not_requested
            in
            respond_json_value_with_cors
              request
              reqd
              (gate_mode_change_json change recovery))))
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | Yojson.Json_error message ->
    respond_json_value_with_cors
      ~status:`Bad_request
      request
      reqd
      (operator_error_json (Printf.sprintf "invalid json: %s" message))
;;

let handle_gate_mode_body state operator_name request reqd body_str =
  handle_gate_mode_body_for_lane
    ~set_mode:Keeper_gate_mode.set
    ~sse_type:"gate_mode_changed"
    state
    operator_name
    request
    reqd
    body_str
;;

let handle_gate_external_mode_body state operator_name request reqd body_str =
  handle_gate_mode_body_for_lane
    ~set_mode:Keeper_gate_mode.set_external
    ~sse_type:"gate_external_mode_changed"
    state
    operator_name
    request
    reqd
    body_str
;;

let handle_gate_resolve_body state operator_name request reqd body_str =
  try
    let args = Yojson.Safe.from_string body_str in
    let workspace_config = Mcp_server.workspace_config state in
    let base_path = workspace_config.Workspace.base_path in
    match dashboard_gate_resolve_http_json ~workspace_config ~base_path ~created_by:operator_name ~args () with
    | Ok json -> respond_json_value_with_cors request reqd json
    | Error (Gone _ as error) ->
      respond_json_value_with_cors
        ~status:`Not_found
        request
        reqd
        (operator_error_json (approval_resolve_http_error_to_string error))
    | Error (Unavailable _ as error) ->
      respond_json_value_with_cors
        ~status:`Service_unavailable
        request
        reqd
        (operator_error_json (approval_resolve_http_error_to_string error))
    | Error (Bad_request _ as error) ->
      respond_json_value_with_cors
        ~status:`Bad_request
        request
        reqd
        (operator_error_json (approval_resolve_http_error_to_string error))
  with
  | Yojson.Json_error message ->
    respond_json_value_with_cors
      ~status:`Bad_request
      request
      reqd
      (operator_error_json (Printf.sprintf "invalid json: %s" message))
;;

let handle_gate_retry_body state operator_name request reqd body_str =
  try
    let args = Yojson.Safe.from_string body_str in
    let workspace_config = Mcp_server.workspace_config state in
    let base_path = workspace_config.Workspace.base_path in
    match dashboard_gate_retry_http_json ~workspace_config ~base_path ~requested_by:operator_name ~args with
    | Ok json -> respond_json_value_with_cors request reqd json
    | Error message ->
      respond_json_value_with_cors
        ~status:`Bad_request
        request
        reqd
        (operator_error_json message)
  with
  | Yojson.Json_error message ->
    respond_json_value_with_cors
      ~status:`Bad_request
      request
      reqd
      (operator_error_json (Printf.sprintf "invalid json: %s" message))
;;

let handle_gate_rule_delete_body state operator_name request reqd body_str =
  try
    let args = Yojson.Safe.from_string body_str in
    let base_path = (Mcp_server.workspace_config state).base_path in
    match
      dashboard_gate_rule_delete_http_json
        ~base_path
        ~deleted_by:operator_name
        ~args
    with
    | Ok json -> respond_json_value_with_cors request reqd json
    | Error message ->
      respond_json_value_with_cors
        ~status:`Bad_request
        request
        reqd
        (operator_error_json message)
  with
  | Yojson.Json_error message ->
    respond_json_value_with_cors
      ~status:`Bad_request
      request
      reqd
      (operator_error_json (Printf.sprintf "invalid json: %s" message))
;;

let add_routes router =
  router
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/gate" (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = dashboard_gate_http_json req ~base_path in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/gate/tool-events" (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = dashboard_gate_tool_events_http_json req ~base_path in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/gate/mode" (fun state operator_name request reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_mode_body state operator_name request reqd))
  (* The same two lists the Gate projection carries, on their own so a surface
     that only wants them does not pay for the approval queue and the resolved
     history to find out which Keepers were singled out. *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/gate/keeper-settings" (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let modes, modes_state =
           match Keeper_gate_mode.keeper_overrides ~base_path with
           | Ok rows ->
             ( `List
                 (List.map
                    (fun (row : Keeper_gate_mode.keeper_override) ->
                      `Assoc
                        [ "keeper_name", `String row.keeper_name
                        ; "mode", `String (Keeper_gate_mode.to_string row.mode)
                        ])
                    rows)
             , `Assoc [ "state", `String "ready" ] )
           | Error detail ->
             ( `List []
             , `Assoc [ "state", `String "unavailable"; "error", `String detail ] )
         in
         let exact_lanes, exact_lanes_state =
           match Keeper_exact_lane_preference.all ~base_path with
           | Ok rows ->
             ( `List
                 (List.map Keeper_exact_lane_preference.to_projection_json rows)
             , `Assoc [ "state", `String "ready" ] )
           | Error detail ->
             ( `List []
             , `Assoc [ "state", `String "unavailable"; "error", `String detail ] )
         in
         Http.Response.json_value ~compress:true ~request:req
           (`Assoc
              [ "modes", modes
              ; "modes_state", modes_state
              ; "exact_lanes", exact_lanes
              ; "exact_lanes_state", exact_lanes_state
              ])
           reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/gate/keeper-mode" (fun state operator_name request reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_keeper_mode_body state operator_name request reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/runtime/keeper-exact-lane" (fun state operator_name request reqd ->
           Http.Request.read_body_async reqd
             (handle_keeper_exact_lane_body state operator_name request reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/gate/external-mode" (fun state operator_name request reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_external_mode_body state operator_name request reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/gate/resolve" (fun state operator_name request reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_resolve_body state operator_name request reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/gate/retry" (fun state operator_name request reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_retry_body state operator_name request reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/gate/rules/delete" (fun state operator_name request reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_rule_delete_body state operator_name request reqd))

module For_testing = struct
  type nonrec gate_mode_recovery = gate_mode_recovery =
    | Recovery_completed of Keeper_gate.operator_recovery_report
    | Recovery_failed of string
    | Recovery_not_requested

  let gate_mode_change_json = gate_mode_change_json
end
