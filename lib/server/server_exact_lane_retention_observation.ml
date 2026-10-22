let replay_to_json = function
  | Run_registry_core.Not_replayed -> `Assoc [ "status", `String "not_replayed" ]
  | Run_registry_core.Log_absent -> `Assoc [ "status", `String "log_absent" ]
  | Run_registry_core.Replayed report ->
    `Assoc
      [ "status", `String "replayed"
      ; "lines_read", `Int report.lines_read
      ; "malformed_lines", `Int report.malformed_lines
      ; "dropped_running", `Int report.dropped_running
      ; "reached_end", `Bool report.reached_end
      ]
;;

let sweep_counts_to_json ~status (counts : Exact_lane_run_registry.payload_sweep_counts) =
  `Assoc
    [ "status", `String status
    ; "examined_root_entries", `Int counts.examined_root_entries
    ; "unlinked_entries", `Int counts.unlinked_entries
    ; "removed_run_directories", `Int counts.removed_run_directories
    ; "failed_root_entries", `Int counts.failed_root_entries
    ]
;;

let sweep_to_json = function
  | Exact_lane_run_registry.Not_attempted ->
    `Assoc [ "status", `String "not_attempted" ]
  | Exact_lane_run_registry.Replay_not_trusted ->
    `Assoc [ "status", `String "replay_not_trusted" ]
  | Exact_lane_run_registry.Root_absent ->
    `Assoc [ "status", `String "root_absent" ]
  | Exact_lane_run_registry.Root_unavailable ->
    `Assoc [ "status", `String "root_unavailable" ]
  | Exact_lane_run_registry.Swept counts ->
    sweep_counts_to_json
      ~status:(if counts.failed_root_entries = 0 then "completed" else "partial_failure")
      counts
  | Exact_lane_run_registry.Sweep_scope_failed counts ->
    sweep_counts_to_json ~status:"scope_failure" counts
;;

let to_json (observation : Exact_lane_run_registry.startup_observation) =
  `Assoc
    [ "scope", `String "process_startup"
    ; "registry_filename", `String Exact_lane_run_registry.storage_filename
    ; "payload_dirname", `String Exact_lane_run_registry.payload_dirname
    ; "completed_retained_per_lane", `Int Exact_lane_run_registry.max_completed_retained
    ; "replay", replay_to_json observation.replay
    ; "payload_sweep", sweep_to_json observation.payload_sweep
    ; "compaction", `Assoc [ "status", `String "unobserved" ]
    ; "failure_log", `Assoc
        [ "channel", `String "keeper"
        ; "prefix", `String "exact_lane_run_registry:"
        ; "messages", `List
            (List.map (fun message -> `String message)
               [ "could not remove payload files of <run_id>"
               ; "could not sweep payload entry <name> under <root>"
               ; "could not list payload entries under <root>"
               ])
        ]
    ]
;;
