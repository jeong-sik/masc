type truth_role =
  | Execution_evidence
  | Derived_projection

type artifact =
  | Execution_receipt
  | Turn_record
  | Runtime_manifest
  | Activity_event
  | Metrics_snapshot
  | Raw_trace
[@@deriving enumerate]

type retention =
  | Dated_jsonl_operator_window
  | Startup_flat_file_mtime
  | Raw_trace_reachability_window

type entry =
  { producer : string
  ; authority_source : string
  ; truth_role : truth_role
  ; consumers : string list
  ; retention : retention
  }

let artifact_label = function
  | Execution_receipt -> "execution_receipt"
  | Turn_record -> "turn_record"
  | Runtime_manifest -> "runtime_manifest"
  | Activity_event -> "activity_event"
  | Metrics_snapshot -> "metrics_snapshot"
  | Raw_trace -> "raw_trace"
;;

let truth_role_label = function
  | Execution_evidence -> "execution_evidence"
  | Derived_projection -> "derived_projection"
;;

let retention_owner = function
  | Dated_jsonl_operator_window -> "Dated_jsonl.Store"
  | Startup_flat_file_mtime -> "Server_runtime_startup_maintenance"
  | Raw_trace_reachability_window -> "Keeper_raw_trace_retention"
;;

let retention_policy = function
  | Dated_jsonl_operator_window ->
    "Operator_window dated JSONL pruning (MASC_JSONL_RETENTION_DAYS)"
  | Startup_flat_file_mtime -> "MASC_JSONL_RETENTION_DAYS flat-file mtime pruning"
  | Raw_trace_reachability_window ->
    "TurnRecord reachability window, plus MASC_JSONL_RETENTION_DAYS mtime fallback"
;;

let entry = function
  | Execution_receipt ->
    { producer = "Keeper_agent_run_receipt"
    ; authority_source = "exact provider/tool terminal result"
    ; truth_role = Execution_evidence
    ; consumers =
        [ "Telemetry_unified"
        ; "Dashboard_http_keeper_execution_receipt"
        ; "Workspace_task_receipts"
        ]
    ; retention = Dated_jsonl_operator_window
    }
  | Turn_record ->
    { producer = "Keeper_turn_record_writer"
    ; authority_source = "execution receipt cadence + admitted turn identity"
    ; truth_role = Derived_projection
    ; consumers =
        [ "Server_dashboard_http_keeper_api"
        ; "Keeper_context_observation_projection"
        ; "Keeper_raw_trace_retention"
        ]
    ; retention = Dated_jsonl_operator_window
    }
  | Runtime_manifest ->
    { producer = "Keeper_runtime_manifest"
    ; authority_source = "turn/provider/checkpoint event writers"
    ; truth_role = Derived_projection
    ; consumers =
        [ "Server_dashboard_http_keeper_runtime_manifest_scan"
        ; "Server_dashboard_http_keeper_runtime_lens_swimlane"
        ]
    ; retention = Startup_flat_file_mtime
    }
  | Activity_event ->
    { producer = "Activity_graph.emit"
    ; authority_source = "typed terminal/tool/board observations"
    ; truth_role = Derived_projection
    ; consumers = [ "Server_activity_http"; "Dashboard_snapshot" ]
    ; retention = Dated_jsonl_operator_window
    }
  | Metrics_snapshot ->
    { producer = "Keeper_unified_metrics_snapshot"
    ; authority_source = "normalized execution outcome + lifecycle projection"
    ; truth_role = Derived_projection
    ; consumers =
        [ "Dashboard_http_keeper_metrics"
        ; "Keeper_status_metrics"
        ; "Telemetry_unified"
        ]
    ; retention = Dated_jsonl_operator_window
    }
  | Raw_trace ->
    { producer = "Agent_core.Raw_trace"
    ; authority_source = "exact provider request/event stream"
    ; truth_role = Execution_evidence
    ; consumers = [ "Turn_record.raw_trace_run_ref"; "Keeper_raw_trace_reader" ]
    ; retention = Raw_trace_reachability_window
    }
;;

let nonblank value = String.trim value <> ""

let validate () =
  List.concat_map
    (fun artifact ->
       let row = entry artifact in
       let label = artifact_label artifact in
       (if row.consumers = [] || not (List.for_all nonblank row.consumers)
        then [ "artifact has no concrete consumer: " ^ label ]
        else [])
       @
       if nonblank row.producer && nonblank row.authority_source
       then []
       else [ "artifact has no producer/authority source: " ^ label ])
    all_of_artifact
;;

let to_yojson () =
  let validation_errors = validate () in
  `Assoc
    [ "schema", `String "masc.keeper_observability_artifacts.v1"
    ; "status", `String (if validation_errors = [] then "ok" else "blocked")
    ; "command_authority", `Bool false
    ; ( "validation_errors"
      , `List (List.map (fun error -> `String error) validation_errors) )
    ; ( "artifacts"
      , `List
          (List.map
             (fun artifact ->
                let row = entry artifact in
                `Assoc
                  [ "artifact", `String (artifact_label artifact)
                  ; "producer", `String row.producer
                  ; "authority_source", `String row.authority_source
                  ; "truth_role", `String (truth_role_label row.truth_role)
                  ; "command_authority", `Bool false
                  ; ( "consumers"
                    , `List (List.map (fun consumer -> `String consumer) row.consumers) )
                  ; "retention_owner", `String (retention_owner row.retention)
                  ; "retention_policy", `String (retention_policy row.retention)
                  ])
             all_of_artifact) )
    ]
;;
