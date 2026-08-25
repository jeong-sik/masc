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

type entry =
  { artifact : artifact
  ; producer : string
  ; authority_source : string
  ; truth_role : truth_role
  ; consumers : string list
  ; retention_owner : string
  ; retention_policy : string
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

let entries =
  [ { artifact = Execution_receipt
    ; producer = "Keeper_agent_run_receipt"
    ; authority_source = "exact provider/tool terminal result"
    ; truth_role = Execution_evidence
    ; consumers =
        [ "Telemetry_unified"
        ; "Dashboard_http_keeper_execution_receipt"
        ; "Workspace_task_receipts"
        ]
    ; retention_owner = "Server_runtime_startup_maintenance"
    ; retention_policy = "MASC_JSONL_RETENTION_DAYS dated JSONL pruning"
    }
  ; { artifact = Turn_record
    ; producer = "Keeper_turn_record_writer"
    ; authority_source = "execution receipt cadence + admitted turn identity"
    ; truth_role = Derived_projection
    ; consumers =
        [ "Server_dashboard_http_keeper_api"
        ; "Keeper_context_observation_projection"
        ; "Keeper_raw_trace_retention"
        ]
    ; retention_owner = "Server_runtime_startup_maintenance"
    ; retention_policy = "MASC_JSONL_RETENTION_DAYS dated JSONL pruning"
    }
  ; { artifact = Runtime_manifest
    ; producer = "Keeper_runtime_manifest"
    ; authority_source = "turn/provider/checkpoint event writers"
    ; truth_role = Derived_projection
    ; consumers =
        [ "Server_dashboard_http_keeper_runtime_manifest_scan"
        ; "Server_dashboard_http_keeper_runtime_lens_swimlane"
        ]
    ; retention_owner = "Server_runtime_startup_maintenance"
    ; retention_policy = "MASC_JSONL_RETENTION_DAYS flat-file mtime pruning"
    }
  ; { artifact = Activity_event
    ; producer = "Activity_graph.emit"
    ; authority_source = "typed terminal/tool/board observations"
    ; truth_role = Derived_projection
    ; consumers = [ "Server_activity_http"; "Dashboard_snapshot" ]
    ; retention_owner = "Server_runtime_startup_maintenance"
    ; retention_policy = "MASC_JSONL_RETENTION_DAYS dated JSONL pruning"
    }
  ; { artifact = Metrics_snapshot
    ; producer = "Keeper_unified_metrics_snapshot"
    ; authority_source = "normalized execution outcome + lifecycle projection"
    ; truth_role = Derived_projection
    ; consumers =
        [ "Dashboard_http_keeper_metrics"
        ; "Keeper_status_metrics"
        ; "Telemetry_unified"
        ]
    ; retention_owner = "Server_runtime_startup_maintenance"
    ; retention_policy = "MASC_JSONL_RETENTION_DAYS dated JSONL pruning"
    }
  ; { artifact = Raw_trace
    ; producer = "Agent_core.Raw_trace"
    ; authority_source = "exact provider request/event stream"
    ; truth_role = Execution_evidence
    ; consumers = [ "Turn_record.raw_trace_run_ref"; "Keeper_raw_trace_reader" ]
    ; retention_owner = "Keeper_raw_trace_retention"
    ; retention_policy =
        "TurnRecord reachability window, plus MASC_JSONL_RETENTION_DAYS mtime fallback"
    }
  ]
;;

let nonblank value = String.trim value <> ""

let validate () =
  let seen = Hashtbl.create (List.length entries) in
  List.fold_left
    (fun errors row ->
       let label = artifact_label row.artifact in
       let errors =
         if Hashtbl.mem seen label
         then ("duplicate artifact: " ^ label) :: errors
         else (
           Hashtbl.add seen label ();
           errors)
       in
       let errors =
         if row.consumers = [] || not (List.for_all nonblank row.consumers)
         then ("artifact has no concrete consumer: " ^ label) :: errors
         else errors
       in
       let errors =
         if nonblank row.retention_owner && nonblank row.retention_policy
         then errors
         else ("artifact has no retention owner/policy: " ^ label) :: errors
       in
       if nonblank row.producer && nonblank row.authority_source
       then errors
       else ("artifact has no producer/authority source: " ^ label) :: errors)
    []
    entries
  |> List.rev
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
             (fun row ->
                `Assoc
                  [ "artifact", `String (artifact_label row.artifact)
                  ; "producer", `String row.producer
                  ; "authority_source", `String row.authority_source
                  ; "truth_role", `String (truth_role_label row.truth_role)
                  ; "command_authority", `Bool false
                  ; ( "consumers"
                    , `List (List.map (fun consumer -> `String consumer) row.consumers) )
                  ; "retention_owner", `String row.retention_owner
                  ; "retention_policy", `String row.retention_policy
                  ])
             entries) )
    ]
;;
