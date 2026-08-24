(* Server_routes_http_runtime_health_fleet — fleet-level health field helpers.
   Extracted from server_routes_http_runtime.ml during godfile decomposition.
   Contains keeper reaction ledger, FD accountant, fleet resolution,
   runtime truth, and contract-verification health JSON renderers. *)

open Server_routes_http_common
open Server_routes_http_runtime_fleet_scan

let keeper_reaction_ledger_health_json () =
  match current_server_state_opt () with
  | None -> Keeper_reaction_ledger.unavailable_fleet_summary_json ()
  | Some state ->
    let config = (Mcp_server.workspace_config state) in
    let keeper_names =
      try Keeper_meta_store.keeper_names config |> sorted_unique_strings with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.warn
          "health: failed to compute keeper reaction ledger names: %s"
          (Printexc.to_string exn);
        []
    in
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path:config.base_path
      ~keeper_names
      ~limit_per_keeper:20
;;

let keeper_owner_health_json () =
  match current_server_state_opt () with
  | None ->
    `Assoc
      [ "schema", `String "masc.keeper_owner.v1"
      ; "status", `String "unavailable"
      ; "operator_action_required", `Bool false
      ; "status_reasons", `List []
      ; "keeper_count", `Int 0
      ; "keeper_names", `List []
      ; "in_flight_keeper_count", `Int 0
      ; "shutdown_keeper_count", `Int 0
      ; "queued_operation_count", `Int 0
      ; "running_operation_count", `Int 0
      ; "terminal_operation_count", `Int 0
      ; "interrupted_operation_count", `Int 0
      ; "keepers", `List []
      ]
  | Some state ->
    let config = Mcp_server.workspace_config state in
    let keeper_names =
      try Keeper_meta_store.keeper_names config |> sorted_unique_strings with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.warn
          "health: failed to compute keeper owner names: %s"
          (Printexc.to_string exn);
        []
    in
    let lane_to_string = function
      | Keeper_owner.Autonomous -> "autonomous"
      | Keeper_owner.Chat_operation -> "chat_operation"
      | Keeper_owner.Maintenance -> "maintenance"
    in
    let row keeper_name =
      match
        Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name
      with
      | Error error ->
        ( `Assoc
            [ "keeper_name", `String keeper_name
            ; "status", `String "unavailable"
            ; ( "detail"
              , `String (Keeper_owner_registry.lookup_error_to_string error) )
            ]
        , 0, 0, 0, 0, 0, 0, 1 )
      | Ok owner ->
        let turn = Keeper_owner.turn_in_flight owner in
        let shutdown = Keeper_owner.shutdown_operation_id owner in
        let operations = Keeper_owner.operation_projection owner in
        let running_count =
          Option.fold ~none:0 ~some:(fun _ -> 1) operations.running_operation_id
        in
        let turn_json =
          match turn with
          | None -> `Null
          | Some turn ->
            `Assoc
              [ "lane", `String (lane_to_string turn.lane)
              ; "started_at_unix", `Float turn.started_at
              ]
        in
        ( `Assoc
            [ "keeper_name", `String keeper_name
            ; ( "status"
              , `String
                  (if operations.store_unavailable then "unavailable" else "ok") )
            ; "turn", turn_json
            ; ( "shutdown_operation_id"
              , match shutdown with
                | None -> `Null
                | Some operation_id ->
                  `String (Keeper_shutdown_types.Operation_id.to_string operation_id) )
            ; "queued_operation_count", `Int operations.queued_count
            ; "running_operation_count", `Int running_count
            ; "terminal_operation_count", `Int operations.terminal_count
            ; "interrupted_operation_count", `Int operations.interrupted_count
            ; "operation_store_unavailable", `Bool operations.store_unavailable
            ]
        , Option.fold ~none:0 ~some:(fun _ -> 1) turn
        , Option.fold ~none:0 ~some:(fun _ -> 1) shutdown
        , operations.queued_count
        , running_count
        , operations.terminal_count
        , operations.interrupted_count
        , if operations.store_unavailable then 1 else 0 )
    in
    let rows = List.map row keeper_names in
    let sum select = List.fold_left (fun total row -> total + select row) 0 rows in
    let unavailable_count = sum (fun (_, _, _, _, _, _, _, count) -> count) in
    `Assoc
      [ "schema", `String "masc.keeper_owner.v1"
      ; "status", `String (if unavailable_count = 0 then "ok" else "degraded")
      ; "operator_action_required", `Bool (unavailable_count > 0)
      ; ( "status_reasons"
        , if unavailable_count = 0
          then `List []
          else `List [ `String "operation_store_unavailable" ] )
      ; "keeper_count", `Int (List.length keeper_names)
      ; "keeper_names", `List (List.map (fun name -> `String name) keeper_names)
      ; ( "in_flight_keeper_count"
        , `Int (sum (fun (_, count, _, _, _, _, _, _) -> count)) )
      ; ( "shutdown_keeper_count"
        , `Int (sum (fun (_, _, count, _, _, _, _, _) -> count)) )
      ; ( "queued_operation_count"
        , `Int (sum (fun (_, _, _, count, _, _, _, _) -> count)) )
      ; ( "running_operation_count"
        , `Int (sum (fun (_, _, _, _, count, _, _, _) -> count)) )
      ; ( "terminal_operation_count"
        , `Int (sum (fun (_, _, _, _, _, count, _, _) -> count)) )
      ; ( "interrupted_operation_count"
        , `Int (sum (fun (_, _, _, _, _, _, count, _) -> count)) )
      ; "keepers", `List (List.map (fun (json, _, _, _, _, _, _, _) -> json) rows)
      ]
;;

let keeper_board_event_collection_health_json () =
  match current_server_state_opt () with
  | None ->
    `Assoc
      [ "schema", `String "masc.keeper_board_event_collection.v1"
      ; "status", `String "unavailable"
      ; "operator_action_required", `Bool false
      ; "status_reasons", `List []
      ; "keeper_count", `Int 0
      ; "keeper_names", `List []
      ; "failure_count", `Int 0
      ; "failures", `List []
      ]
  | Some state ->
    let config = Mcp_server.workspace_config state in
    let keeper_names =
      try Keeper_meta_store.keeper_names config |> sorted_unique_strings with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.warn
          "health: failed to compute board event collection keeper names: %s"
          (Printexc.to_string exn);
        []
    in
    Keeper_heartbeat_loop_board_events.fleet_health_json
      ~base_path:config.base_path
      ~keeper_names
;;

let paused_keeper_count = function
  | `Assoc fields ->
      (match List.assoc_opt "count" fields with
       | Some (`Int count) -> count
       | _ -> 0)
  | _ -> 0
;;

(* Scope keeper counts to the active workspace's base_path so a running
   keeper from another workspace cannot mask a local outage in fleet
   safety. `bootable_keeper_count` is already derived from
   `(Mcp_server.workspace_config state)`, so the running count must use the same scope. *)
let runtime_base_path_opt () =
  match current_server_state_opt () with
  | Some state -> Some (Mcp_server.workspace_config state).base_path
  | None -> None

let queue_assoc_int name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> value
  | _ -> 0
;;

let queue_assoc_float_opt name fields =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let queue_assoc_bool name ~default fields =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> value
  | _ -> default
;;

let keeper_event_queue_health_dimensions ~stale_after_sec = function
  | `Assoc fields ->
    let source_status =
      match List.assoc_opt "status" fields with
      | Some (`String value) -> value
      | _ -> "unknown"
    in
    let source_unavailable =
      match Health_status.of_string source_status with
      | Health_status.Unavailable
      | Health_status.Unknown
      | Health_status.Blocked
      | Health_status.Error
      | Health_status.Timeout ->
        true
      | Health_status.Ok
      | Health_status.Idle
      | Health_status.Warming
      | Health_status.Snapshot_not_ready
      | Health_status.Degraded
      | Health_status.Stale
      | Health_status.Warning ->
        false
    in
    let counts_complete = queue_assoc_bool "counts_complete" ~default:false fields in
    let read_error_count = queue_assoc_int "read_error_count" fields in
    let transition_outbox_count = queue_assoc_int "transition_outbox_count" fields in
    let runnable_backlog_count = queue_assoc_int "runnable_backlog_count" fields in
    let recoverable_backlog_count =
      queue_assoc_int "recoverable_backlog_count" fields
    in
    let retained_disabled_backlog_count =
      queue_assoc_int "retained_disabled_backlog_count" fields
    in
    let paused_dead_backlog_count =
      queue_assoc_int "paused_dead_backlog_count" fields
    in
    let shutdown_fenced_backlog_count =
      queue_assoc_int "shutdown_fenced_backlog_count" fields
    in
    (* Only part of the non-runnable backlog is something an operator can act
       on.  [recoverable] clears once the owner fiber is restored and
       [shutdown_fenced] clears once the shutdown completes, so both warrant a
       prompt.  [retained_disabled] and [paused_dead] are the operator's own
       standing decision -- a keeper deliberately paused, or autoboot /
       proactive turned off.  Counting those as actionable pinned
       [operator_action_required] to true for as long as the decision held, so
       one deliberately paused keeper produced a permanent alarm that buried
       the ones that do need an answer.  Both counts still travel in
       [status_reasons], so the backlog stays visible without demanding
       action. *)
    let actionable_backlog_count =
      recoverable_backlog_count + shutdown_fenced_backlog_count
    in
    (* [backlog_clean] answers a different question than [work_action_required]:
       it reports whether the queue holds anything at all, so an operator-paused
       entry does count against it. Keep the total separate from the actionable
       subset. *)
    let non_runnable_backlog_count =
      actionable_backlog_count
      + retained_disabled_backlog_count
      + paused_dead_backlog_count
    in
    let runnable_oldest_age_seconds =
      queue_assoc_float_opt "runnable_oldest_age_seconds" fields
    in
    let storage_degraded =
      (not source_unavailable)
      && ((not counts_complete) || read_error_count > 0 || transition_outbox_count > 0)
    in
    let storage_status =
      if source_unavailable then "unavailable"
      else if storage_degraded then "degraded"
      else "ok"
    in
    let backlog_stale =
      runnable_backlog_count > 0
      && Option.fold
           ~none:false
           ~some:(fun age -> age >= stale_after_sec)
           runnable_oldest_age_seconds
    in
    let work_status, work_state =
      if source_unavailable || not counts_complete
      then "unavailable", "unknown"
      else if backlog_stale
      then "degraded", "stalled"
      else if runnable_backlog_count > 0
      then "warning", "backlogged"
      else if actionable_backlog_count > 0
      then "warning", "blocked"
      else "ok", "idle"
    in
    let source_action_required =
      queue_assoc_bool "operator_action_required" ~default:false fields
    in
    let work_action_required =
      backlog_stale || actionable_backlog_count > 0
    in
    let operator_action_required =
      source_action_required || storage_degraded || work_action_required
    in
    let status =
      Health_status.max_string
        source_status
        (Health_status.max_string storage_status work_status)
    in
    (* A backlog reason carries how deep the backlog is. Without it every size
       reads the same on screen: thirty paused keepers holding 560 stimuli look
       exactly like one keeper holding one. The dashboard joins these strings as
       they arrive and already shows key=value entries beside them
       (status=…, operator_action_required=…), so the count travels without a
       schema change. *)
    let backlog_reason name count reasons =
      if count > 0 then Printf.sprintf "%s=%d" name count :: reasons else reasons
    in
    let status_reasons =
      []
      |> (fun reasons ->
        if not counts_complete then "storage_counts_incomplete" :: reasons else reasons)
      |> (fun reasons ->
        if read_error_count > 0 then "storage_read_error" :: reasons else reasons)
      |> (fun reasons ->
        if transition_outbox_count > 0
        then "transition_projection_pending" :: reasons
        else reasons)
      |> backlog_reason "runnable_backlog" runnable_backlog_count
      |> backlog_reason "recoverable_backlog" recoverable_backlog_count
      |> backlog_reason "retained_disabled_backlog" retained_disabled_backlog_count
      |> backlog_reason "paused_dead_backlog" paused_dead_backlog_count
      |> backlog_reason "shutdown_fenced_backlog" shutdown_fenced_backlog_count
      |> (fun reasons ->
        if backlog_stale then "runnable_backlog_stale" :: reasons else reasons)
      |> List.rev
    in
    let without name fields = List.remove_assoc name fields in
    let fields =
      fields
      |> without "schema"
      |> without "status"
      |> without "operator_action_required"
      |> without "status_reasons"
      |> without "storage_integrity"
      |> without "work_liveness"
      |> without "backlog_clean"
    in
    `Assoc
      ([ "schema", `String "masc.keeper_event_queue.fleet_summary.v4"
       ; "status", `String status
       ; "operator_action_required", `Bool operator_action_required
       ; "status_reasons", `List (List.map (fun reason -> `String reason) status_reasons)
       ; ( "backlog_clean"
         , `Bool
             (counts_complete
              && (not source_unavailable)
              && read_error_count = 0
              && transition_outbox_count = 0
              && runnable_backlog_count = 0
              && non_runnable_backlog_count = 0) )
       ; ( "storage_integrity"
         , `Assoc
             [ "schema", `String "masc.keeper_event_queue.storage_integrity.v1"
             ; "status", `String storage_status
             ; "counts_complete", `Bool counts_complete
             ; "read_error_count", `Int read_error_count
             ; "transition_outbox_count", `Int transition_outbox_count
             ; "operator_action_required", `Bool storage_degraded
             ] )
       ; ( "work_liveness"
         , `Assoc
             [ "schema", `String "masc.keeper_event_queue.work_liveness.v1"
             ; "status", `String work_status
             ; "state", `String work_state
             ; "runnable_backlog_count", `Int runnable_backlog_count
             ; ( "runnable_oldest_age_seconds"
               , Option.fold
                   ~none:`Null
                   ~some:(fun value -> `Float value)
                   runnable_oldest_age_seconds )
             ; "stale_after_seconds", `Float stale_after_sec
             ; "operator_action_required", `Bool work_action_required
             ] )
       ]
       @ fields)
  | json -> json
;;

let keeper_event_queue_health_json ~execution_snapshot () =
  let stale_after_sec = Env_config.KeeperHealth.durable_queue_stale_sec () in
  match current_server_state_opt () with
  | None ->
    keeper_event_queue_health_dimensions ~stale_after_sec
      (`Assoc
      [ "schema", `String "masc.keeper_event_queue.fleet_summary.v3"
      ; "status", `String "unavailable"
      ; "operator_action_required", `Bool false
      ; "keeper_count", `Int 0
      ; "keeper_names", `List []
      ; "pending_count", `Int 0
      ; "total_count", `Int 0
      ; "transition_outbox_count", `Int 0
      ; "counts_complete", `Bool false
      ; "oldest_arrived_at_unix", `Null
      ; "oldest_age_seconds", `Null
      ; "runnable_backlog_count", `Int 0
      ; "runnable_oldest_arrived_at_unix", `Null
      ; "runnable_oldest_age_seconds", `Null
      ; "runnable_by_keeper", `List []
      ; "recoverable_backlog_count", `Int 0
      ; "recoverable_oldest_arrived_at_unix", `Null
      ; "recoverable_oldest_age_seconds", `Null
      ; "recoverable_by_keeper", `List []
      ; "retained_disabled_backlog_count", `Int 0
      ; "retained_disabled_oldest_arrived_at_unix", `Null
      ; "retained_disabled_oldest_age_seconds", `Null
      ; "retained_disabled_by_keeper", `List []
      ; "paused_dead_backlog_count", `Int 0
      ; "paused_dead_oldest_arrived_at_unix", `Null
      ; "paused_dead_oldest_age_seconds", `Null
      ; "paused_dead_by_keeper", `List []
      ; "shutdown_fenced_backlog_count", `Int 0
      ; "shutdown_fenced_oldest_arrived_at_unix", `Null
      ; "shutdown_fenced_oldest_age_seconds", `Null
      ; "shutdown_fenced_by_keeper", `List []
      ; "unclassified_count", `Int 0
      ; "unclassified_oldest_arrived_at_unix", `Null
      ; "unclassified_oldest_age_seconds", `Null
      ; "unclassified_by_keeper", `List []
      ; "pending_by_keeper", `List []
      ; "read_error_count", `Int 0
      ; "read_errors", `List []
      ; "keepers", `List []
      ])
  | Some state ->
    let config = Mcp_server.workspace_config state in
    let base_path = config.base_path in
    let now =
      Unix.gettimeofday ()
      (* NDT-OK: full health samples wall-clock at the HTTP boundary to report
         durable queue ages; queue parsing below stays deterministic. *)
    in
    let owner_lifecycle ~keeper_name =
      match
        owner_execution_truth execution_snapshot ~keeper_name
      with
      | Keeper_activation_readiness.Executable ->
        Keeper_event_queue_persistence.Runnable
      | Keeper_activation_readiness.Recoverable ->
        Keeper_event_queue_persistence.Recoverable
      | Keeper_activation_readiness.Retained_disabled _
        -> Keeper_event_queue_persistence.Retained_disabled
      | Keeper_activation_readiness.Paused_dead _ ->
        Keeper_event_queue_persistence.Paused_dead
      | Keeper_activation_readiness.Shutdown_fenced _ ->
        Keeper_event_queue_persistence.Shutdown_fenced
      | Keeper_activation_readiness.Unknown detail ->
        Keeper_event_queue_persistence.Lifecycle_unknown detail
    in
    Keeper_event_queue_persistence.fleet_summary_json
      ~now
      ~base_path
      ~owner_lifecycle
    |> keeper_event_queue_health_dimensions ~stale_after_sec

let keeper_fleet_runtime_resolution_base_fields
    ?meta_scan
    ?(include_reaction_ledger = true)
    () =
  let base_path = runtime_base_path_opt () in
  let phase_snapshot = keeper_phase_snapshot ?base_path () in
  let execution_snapshot =
    match current_server_state_opt () with
    | Some state ->
      keeper_execution_snapshot (Mcp_server.workspace_config state)
    | None -> empty_keeper_execution_snapshot
  in
  let phase_counts = phase_snapshot.counts in
  let keeper_fibers = phase_counts.running in
  let paused_keepers_json =
    match meta_scan with
    | Some scan ->
      paused_keepers_health_json_of_scan
        ~registry_paused_names:(registry_paused_keeper_names ())
        scan.paused_scan
    | None -> paused_keepers_health_json ()
  in
  let fleet_safety =
    match meta_scan with
    | Some scan ->
      keeper_fleet_safety_health_json
        ~bootable_names:scan.bootable_names
        ~autoboot_scan:scan.autoboot_scan
        ~phase_snapshot
        ~execution_snapshot
        ?base_path
        ~phase_counts
        ~paused_keepers_json
        ()
  | None ->
      keeper_fleet_safety_health_json
        ~phase_snapshot
        ~execution_snapshot
        ?base_path
      ~phase_counts
      ~paused_keepers_json
      ()
  in
  let disk_observation =
    match base_path with
    | Some base_path ->
      Keeper_disk_pressure.snapshot_json
        ~masc_root:(Workspace_utils.masc_dir_from_base_path ~base_path)
        ()
    | None -> `Null
  in
  let fields =
    [ "keeper_fibers", `Int keeper_fibers
    ; "paused_keepers", `Int (paused_keeper_count paused_keepers_json)
    ; "paused_keepers_health", paused_keepers_json
    ; ( "fd_observation"
      , Keeper_fd_pressure.runtime_state_json ~active_keepers:keeper_fibers
          () )
    ; "disk_observation", disk_observation
    ; "keeper_fleet_safety", fleet_safety
    ; "keeper_owner", keeper_owner_health_json ()
    ; "keeper_board_event_collection", keeper_board_event_collection_health_json ()
    ]
  in
  if include_reaction_ledger
  then fields @ [ "keeper_reaction_ledger", keeper_reaction_ledger_health_json () ]
  else fields
;;

let fd_accountant_snapshot_json () =
  let snapshot = Fd_accountant.fd_snapshot () in
  let observed_int = function
    | Some value -> `Int value
    | None -> `Null
  in
  let per_kind =
    snapshot.per_kind
    |> List.map (fun (kind, active_operations) ->
      let kind_name = Fd_accountant.kind_to_string kind in
      `Assoc
        [ "kind", `String kind_name
        ; "active_operations", `Int active_operations
        ])
  in
  let resource_errors =
    snapshot.resource_errors
    |> List.map (fun (kind, error, count) ->
      `Assoc
        [ "kind", `String (Fd_accountant.kind_to_string kind)
        ; "error", `String (Fd_accountant.resource_error_to_string error)
        ; "count", `Int count
        ])
  in
  `Assoc
    [ "fd_open", observed_int snapshot.fd_open
    ; "fd_limit", observed_int snapshot.fd_limit
    ; "per_kind", `List per_kind
    ; "resource_errors", `List resource_errors
    ]
;;

let runtime_truth_json ~build ~path_diagnostics ~keeper_fibers ~fd_accountant =
  `Assoc
    [ "schema", `String "masc.runtime_truth.v1"
    ; "source", `String "running_process"
    ; "effective_base_path", `String path_diagnostics.Server_base_path_diagnostics.effective_base_path
    ; "effective_masc_root", `String path_diagnostics.effective_masc_root
    ; "process_cwd", `String path_diagnostics.process_cwd
    ; ( "input_base_path"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) path_diagnostics.input_base_path
      )
    ; ( "env_masc_base_path"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) path_diagnostics.env_masc_base_path
      )
    ; "runtime_repo_root", Option.fold ~none:`Null ~some:(fun value -> `String value) build.Build_identity.repo_root
    ; "executable_path", `String build.executable_path
    ; "executable_dir", `String build.executable_dir
    ; "runtime_commit", Option.fold ~none:`Null ~some:(fun value -> `String value) build.commit
    ; "runtime_commit_source", Option.fold ~none:`Null ~some:(fun value -> `String value) build.commit_source
    ; "binary_commit", Option.fold ~none:`Null ~some:(fun value -> `String value) build.binary_commit
    ; "binary_commit_source", Option.fold ~none:`Null ~some:(fun value -> `String value) build.binary_commit_source
    ; "repo_head_commit", Option.fold ~none:`Null ~some:(fun value -> `String value) build.repo_head_commit
    ; "repo_head_commit_source", Option.fold ~none:`Null ~some:(fun value -> `String value) build.repo_head_commit_source
    ; "keeper_fibers", `Int keeper_fibers
    ; "fd_open", (match Json_util.assoc_member_opt "fd_open" fd_accountant with Some v -> v | None -> `Null)
    ; "fd_limit", (match Json_util.assoc_member_opt "fd_limit" fd_accountant with Some v -> v | None -> `Null)
    ]
;;

let keeper_fleet_runtime_resolution_fields () =
  keeper_fleet_runtime_resolution_base_fields ()
  @ [ "fd_accountant", fd_accountant_snapshot_json () ]
;;

let keeper_fleet_runtime_resolution_light_fields () =
  let meta_scan =
    match current_server_state_opt () with
    | Some state ->
      Some
        (keeper_fleet_meta_scan
           ~include_paused_details:false
           (Mcp_server.workspace_config state))
    | None -> None
  in
  keeper_fleet_runtime_resolution_base_fields
    ?meta_scan
    ~include_reaction_ledger:false
    ()
  @ [ "fd_accountant", fd_accountant_snapshot_json () ]
;;
