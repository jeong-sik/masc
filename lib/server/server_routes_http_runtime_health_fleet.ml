(* Server_routes_http_runtime_health_fleet — fleet-level health field helpers.
   Extracted from server_routes_http_runtime.ml during godfile decomposition.
   Contains keeper reaction ledger, FD accountant, fleet resolution,
   runtime truth, and contract-verification health JSON renderers. *)

open Server_utils
open Server_auth
open Server_routes_http_common
open Server_routes_http_runtime_fleet_scan

let take = List.take
;;

let keeper_reaction_ledger_health_json () =
  match current_server_state_opt () with
  | None ->
    `Assoc
      [ "schema", `String "keeper.reaction_ledger.fleet_summary.v1"
      ; "status", `String "unavailable"
      ; "status_reasons", `List []
      ; "operator_action_required", `Bool false
      ; "keeper_count", `Int 0
      ; "keeper_names", `List []
      ; "scanned_row_limit_per_keeper", `Int 20
      ; "row_count", `Int 0
      ; "stimulus_count", `Int 0
      ; "reaction_count", `Int 0
      ; "pending_stimulus_count", `Int 0
      ; "durable_event_queue_count", `Int 0
      ; "durable_event_queue_pending_count", `Int 0
      ; "durable_event_queue_inflight_count", `Int 0
      ; "durable_event_queue_discovered_keeper_count", `Int 0
      ; "durable_event_queue_discovered_keeper_names", `List []
      ; "durable_event_queue_discovery_error", `Null
      ; "durable_event_queue_discovery_error_count", `Int 0
      ; ( "durable_event_queue_stale_after_sec"
        , `Float (Env_config.KeeperHealth.durable_queue_stale_sec ()) )
      ; "durable_event_queue_stale_count", `Int 0
      ; "durable_event_queue_stale_keeper_count", `Int 0
      ; "durable_event_queue_read_error_count", `Int 0
      ; "durable_event_queue_read_errors_by_keeper", `List []
      ; "durable_event_queue_by_keeper", `List []
      ; "durable_event_queue_stale_by_keeper", `List []
      ; "durable_event_queue_payload_counts", `List []
      ; "pending_by_keeper", `List []
      ; "read_error_count", `Int 0
      ; "keepers", `List []
      ]
  | Some state ->
    let config = (Mcp_server.workspace_config state) in
    let keeper_names =
      try Keeper_meta_store.keeper_names config |> sorted_unique_strings |> take 64 with
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

let keeper_turn_admission_health_json () =
  match current_server_state_opt () with
  | None ->
    `Assoc
      [ "schema", `String "masc.keeper_turn_admission.v1"
      ; "status", `String "unavailable"
      ; "operator_action_required", `Bool false
      ; "status_reasons", `List []
      ; "keeper_count", `Int 0
      ; "keeper_names", `List []
      ; "max_waiting_chat_requests", `Int Keeper_turn_admission.max_waiting_chat_requests
      ; "chat_waiting_keeper_count", `Int 0
      ; "chat_waiting_total_count", `Int 0
      ; "chat_waiting_full_keeper_count", `Int 0
      ; "chat_rejected_total_count", `Int 0
      ; "in_flight_keeper_count", `Int 0
      ; "keepers", `List []
      ]
  | Some state ->
    let config = Mcp_server.workspace_config state in
    let keeper_names =
      try Keeper_meta_store.keeper_names config |> sorted_unique_strings with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.warn
          "health: failed to compute keeper turn admission names: %s"
          (Printexc.to_string exn);
        []
    in
    Keeper_turn_admission.fleet_health_json ~base_path:config.base_path ~keeper_names
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
      ; "failed_keeper_count", `Int 0
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

let bool_field name = function
  | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some (`Bool value) -> value
       | _ -> false)
  | _ -> false
;;

(* Scope keeper counts to the active workspace's base_path so a running
   keeper from another workspace cannot mask a local outage in fleet
   safety. `bootable_keeper_count` is already derived from
   `(Mcp_server.workspace_config state)`, so the running count must use the same scope. *)
let runtime_base_path_opt () =
  match current_server_state_opt () with
  | Some state -> Some (Mcp_server.workspace_config state).base_path
  | None -> None

let keeper_fleet_runtime_resolution_base_fields
    ?meta_scan
    ?(include_reaction_ledger = true)
    () =
  let base_path = runtime_base_path_opt () in
  let phase_snapshot = keeper_phase_snapshot ?base_path () in
  let phase_counts = phase_snapshot.counts in
  let keeper_fibers = phase_counts.running in
  let paused_keepers_json =
    match meta_scan with
    | Some scan ->
      paused_keepers_health_json_of_scan
        ~running_names:(running_paused_keeper_names ())
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
        ?base_path
        ~phase_counts
        ~paused_keepers_json
        ()
  | None ->
    keeper_fleet_safety_health_json
      ~phase_snapshot
      ?base_path
      ~phase_counts
      ~paused_keepers_json
      ()
  in
  let fields =
    [ "keeper_fibers", `Int keeper_fibers
    ; "paused_keepers", `Int (paused_keeper_count paused_keepers_json)
    ; "paused_keepers_health", paused_keepers_json
    ; "keeper_fleet_no_fibers", `Bool (bool_field "no_running_fibers" fleet_safety)
    ; ( "keeper_fd_pressure"
      , Keeper_fd_pressure.runtime_state_json ~active_keepers:keeper_fibers
          ~starting_keepers:0 ~requested_keepers:24 () )
    ; "keeper_fleet_safety", fleet_safety
    ; "keeper_turn_admission", keeper_turn_admission_health_json ()
    ; "keeper_board_event_collection", keeper_board_event_collection_health_json ()
    ]
  in
  if include_reaction_ledger
  then fields @ [ "keeper_reaction_ledger", keeper_reaction_ledger_health_json () ]
  else fields
;;

let fd_accountant_snapshot_json () =
  let snapshot = Fd_accountant.fd_snapshot () in
  let per_kind =
    snapshot.per_kind
    |> List.map (fun (kind, in_flight) ->
      let kind_name = Fd_accountant.kind_to_string kind in
      `Assoc
        [ "kind", `String kind_name
        ; "in_flight", `Int in_flight
        ; "configured_concurrency", `Int (Fd_accountant.configured_concurrency ~kind)
        ; "effective_concurrency", `Int (Fd_accountant.effective_concurrency ~kind)
        ])
  in
  `Assoc
    [ "fd_open", `Int snapshot.fd_open
    ; "fd_limit", `Int snapshot.fd_limit
    ; "pressure_active", `Bool snapshot.pressure_active
    ; "per_kind", `List per_kind
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
    ; "fd_pressure_active", (match Json_util.assoc_member_opt "pressure_active" fd_accountant with Some v -> v | None -> `Null)
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
