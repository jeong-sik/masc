module Base = struct
  type t =
    | Transition_audit
    | Audit_approvals
    | Tool_events
    | Keeper_wake_payload
    | Verdicts
  [@@deriving enumerate]

  let dirname = function
    | Transition_audit -> "transition-audit"
    | Audit_approvals -> "audit-approvals"
    | Tool_events -> "tool-events"
    | Keeper_wake_payload -> "keeper-wake-payload"
    | Verdicts -> "verdicts"
end

module Cluster = struct
  type t =
    | Audit
    | Telemetry
    | Events
    | Activity_events
    | Tool_calls
    | Tool_usage
    | Agent_core_events
    | Costs
    | Provider_usage_history
    | Wire_capture
    | Schedule_signals
    | Telemetry_coverage_gaps
  [@@deriving enumerate]

  (* The path below the cluster root. Schedule signals sit one level down,
     beside the schedule ledger. *)
  let segments = function
    | Audit -> [ "audit" ]
    | Telemetry -> [ "telemetry" ]
    | Events -> [ "events" ]
    | Activity_events -> [ "activity-events" ]
    | Tool_calls -> [ "tool_calls" ]
    | Tool_usage -> [ "tool_usage" ]
    | Agent_core_events -> [ "agent-core-events" ]
    | Costs -> [ "costs" ]
    | Provider_usage_history -> [ "provider_usage_history" ]
    | Wire_capture -> [ "wire-capture" ]
    | Schedule_signals -> [ "schedules"; "signals" ]
    | Telemetry_coverage_gaps -> [ "telemetry-coverage-gaps" ]

  let relative_path store = String.concat Filename.dir_sep (segments store)
end

module Keeper = struct
  type t =
    | Metrics
    | Execution_receipts
    | Turn_records
    | Provider_inputs
    | Memory_recall_artifacts
    | Crash_events
    | Continuity_requests
  [@@deriving enumerate]

  (* Six of these are also [Common.keeper_runtime_store] entries; their names
     are read from there so the two cannot drift. *)
  let dirname = function
    | Metrics -> Common.keeper_runtime_store_dirname Common.Keeper_metrics
    | Execution_receipts ->
      Common.keeper_runtime_store_dirname Common.Keeper_execution_receipts
    | Turn_records -> Common.keeper_runtime_store_dirname Common.Keeper_turn_records
    | Provider_inputs ->
      Common.keeper_runtime_store_dirname Common.Keeper_provider_inputs
    | Memory_recall_artifacts ->
      Common.keeper_runtime_store_dirname Common.Keeper_memory_recall_artifacts
    | Crash_events -> Common.keeper_runtime_store_dirname Common.Keeper_crash_events
    | Continuity_requests -> "continuity-requests"
end

type t =
  | Base of Base.t
  | Cluster of Cluster.t
  | Keeper of Keeper.t
  | Reaction_ledger
  | Decision_audit
[@@deriving enumerate]

type location = { dir : string }

let under root segments = { dir = List.fold_left Filename.concat root segments }
let base_root ~base_path = Common.masc_dir_from_base_path ~base_path
let base ~base_path store = under (base_root ~base_path) [ Base.dirname store ]

let reaction_ledger ~base_path ~keeper ~generation =
  under
    (base_root ~base_path)
    [ Common.keepers_runtime_dirname
    ; keeper
    ; Common.keeper_runtime_store_dirname Common.Keeper_reaction_ledger
    ; generation
    ]

let decision_audit_dirname = "decision_audit"

let decision_audit ~base_path ~keeper_dirname =
  under (base_root ~base_path) [ decision_audit_dirname; keeper_dirname ]

type cluster_root = Cluster_root of string

let cluster_root dir = Cluster_root dir
let cluster (Cluster_root root) store = under root (Cluster.segments store)

let keeper (Cluster_root root) ~keeper store =
  under root [ Common.keepers_runtime_dirname; keeper; Keeper.dirname store ]

let dir location = location.dir

type retention =
  | Operator_window
  | Fixed_days of int
  | Own_days of (unit -> int)
  | Kept

(* The provider usage page asks for at most 14 days
   ([Server_provider_usage_history.window]). The store has kept 16. *)
let provider_usage_history_days = 16

let base_retention = function
  | Base.Transition_audit
  | Base.Audit_approvals
  | Base.Tool_events
  | Base.Keeper_wake_payload -> Operator_window
  (* Human labels cannot be made again, and the verdict statistics read
     the newest 5,000 rows (about half a year at the 2026-10 rate). *)
  | Base.Verdicts -> Kept

let cluster_retention = function
  | Cluster.Audit
  | Cluster.Telemetry
  | Cluster.Events
  | Cluster.Activity_events
  | Cluster.Tool_calls
  | Cluster.Tool_usage
  | Cluster.Agent_core_events
  | Cluster.Costs -> Operator_window
  | Cluster.Provider_usage_history -> Fixed_days provider_usage_history_days
  | Cluster.Wire_capture -> Own_days Env_config_keeper.KeeperWireCapture.retention_days
  (* Only the dashboard reads signal rows; [schedules/signal_keys.json]
     keeps a signal from firing twice. *)
  | Cluster.Schedule_signals | Cluster.Telemetry_coverage_gaps -> Operator_window

let keeper_retention = function
  | Keeper.Metrics
  | Keeper.Execution_receipts
  | Keeper.Turn_records
  | Keeper.Provider_inputs
  | Keeper.Memory_recall_artifacts
  | Keeper.Crash_events
  | Keeper.Continuity_requests -> Operator_window

let retention = function
  | Base store -> base_retention store
  | Cluster store -> cluster_retention store
  | Keeper store -> keeper_retention store
  | Reaction_ledger | Decision_audit -> Operator_window

let subdirectories root =
  if Sys.file_exists root && Sys.is_directory root
  then
    Sys.readdir root
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter (fun name -> Sys.is_directory (Filename.concat root name))
  else []

let existing location = if Sys.file_exists location.dir then [ location ] else []

let locations_on_disk ~base_path (Cluster_root root as cluster_root) store =
  match store with
  | Base store -> existing (base ~base_path store)
  | Cluster store -> existing (cluster cluster_root store)
  | Keeper store ->
    subdirectories (Filename.concat root Common.keepers_runtime_dirname)
    |> List.concat_map (fun keeper_name ->
      existing (keeper cluster_root ~keeper:keeper_name store))
  | Reaction_ledger ->
    let keepers = Filename.concat (base_root ~base_path) Common.keepers_runtime_dirname in
    subdirectories keepers
    |> List.concat_map (fun keeper_name ->
      let ledger =
        List.fold_left
          Filename.concat
          keepers
          [ keeper_name
          ; Common.keeper_runtime_store_dirname Common.Keeper_reaction_ledger
          ]
      in
      subdirectories ledger
      |> List.map (fun generation ->
        reaction_ledger ~base_path ~keeper:keeper_name ~generation))
  | Decision_audit ->
    subdirectories (Filename.concat (base_root ~base_path) decision_audit_dirname)
    |> List.map (fun keeper_dirname -> decision_audit ~base_path ~keeper_dirname)
let dated_path location ~ts = Jsonl_writer.dated_path ~base_dir:location.dir ~ts
let dated_path_now location = Jsonl_writer.dated_path_now ~base_dir:location.dir
