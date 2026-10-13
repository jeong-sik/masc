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

let decision_audit ~base_path ~keeper_dirname =
  under (base_root ~base_path) [ "decision_audit"; keeper_dirname ]

type cluster_root = Cluster_root of string

let cluster_root dir = Cluster_root dir
let cluster (Cluster_root root) store = under root (Cluster.segments store)

let keeper (Cluster_root root) ~keeper store =
  under root [ Common.keepers_runtime_dirname; keeper; Keeper.dirname store ]

let dir location = location.dir
let dated_path location ~ts = Jsonl_writer.dated_path ~base_dir:location.dir ~ts
let dated_path_now location = Jsonl_writer.dated_path_now ~base_dir:location.dir
