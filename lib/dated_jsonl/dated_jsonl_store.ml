module Root = struct
  type t =
    | Transition_audit
    | Audit_approvals
    | Tool_events
    | Keeper_wake_payload
    | Verdicts
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

  (* The path below [<base>/.masc]. Schedule signals sit one level down,
     beside the schedule ledger. *)
  let segments = function
    | Transition_audit -> [ "transition-audit" ]
    | Audit_approvals -> [ "audit-approvals" ]
    | Tool_events -> [ "tool-events" ]
    | Keeper_wake_payload -> [ "keeper-wake-payload" ]
    | Verdicts -> [ "verdicts" ]
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
  | Root of Root.t
  | Keeper of Keeper.t
  | Reaction_ledger
  | Decision_audit
[@@deriving enumerate]

type location = { store : t; dir : string; root : string; segments : string list }
type root = Masc_dir of string

let root_of_base_path ~base_path = Masc_dir (Common.masc_dir_from_base_path ~base_path)
let root_of_masc_dir dir = Masc_dir dir
let under (Masc_dir root) store segments =
  { store; dir = List.fold_left Filename.concat root segments; root; segments }
let at root store = under root (Root store) (Root.segments store)

let keeper root ~keeper store =
  under root (Keeper store) [ Common.keepers_runtime_dirname; keeper; Keeper.dirname store ]

let reaction_ledger root ~keeper ~generation =
  under
    root
    Reaction_ledger
    [ Common.keepers_runtime_dirname
    ; keeper
    ; Common.keeper_runtime_store_dirname Common.Keeper_reaction_ledger
    ; generation
    ]

let decision_audit_dirname = "decision_audit"

let decision_audit root ~keeper_dirname =
  under root Decision_audit [ decision_audit_dirname; keeper_dirname ]

let dir location = location.dir
let of_location location = location.store

let pool_job_name = function
  | Root store -> "root/" ^ Root.relative_path store
  | Keeper store -> "keeper/" ^ Keeper.dirname store
  | Reaction_ledger ->
    "keeper/" ^ Common.keeper_runtime_store_dirname Common.Keeper_reaction_ledger
  | Decision_audit -> decision_audit_dirname

type retention =
  | Operator_window
  | Fixed_days of int
  | Own_days of (unit -> int)
  | Kept

(* The provider usage page asks for at most 14 days
   ([Server_provider_usage_history.window]). The store has kept 16. *)
let provider_usage_history_days = 16

let root_retention = function
  | Root.Transition_audit
  | Root.Audit_approvals
  | Root.Tool_events
  | Root.Keeper_wake_payload
  | Root.Audit
  | Root.Telemetry
  | Root.Events
  | Root.Activity_events
  | Root.Tool_calls
  | Root.Tool_usage
  | Root.Agent_core_events
  | Root.Costs -> Operator_window
  (* Human labels cannot be made again, and the verdict statistics read
     the newest 5,000 rows (about half a year at the 2026-10 rate). *)
  | Root.Verdicts -> Kept
  | Root.Provider_usage_history -> Fixed_days provider_usage_history_days
  | Root.Wire_capture -> Own_days Env_config_keeper.KeeperWireCapture.retention_days
  (* Only the dashboard reads signal rows; [schedules/signal_keys.json]
     keeps a signal from firing twice. *)
  | Root.Schedule_signals | Root.Telemetry_coverage_gaps -> Operator_window

let keeper_retention = function
  | Keeper.Metrics
  | Keeper.Execution_receipts
  | Keeper.Turn_records
  | Keeper.Provider_inputs
  | Keeper.Memory_recall_artifacts
  | Keeper.Crash_events
  | Keeper.Continuity_requests -> Operator_window

let retention = function
  | Root store -> root_retention store
  | Keeper store -> keeper_retention store
  | Reaction_ledger | Decision_audit -> Operator_window

let existing location = if Sys.file_exists location.dir then [ location ] else []

let locations_on_disk (Masc_dir dir as root) store =
  let keepers = Filename.concat dir Common.keepers_runtime_dirname in
  match store with
  | Root store -> existing (at root store)
  | Keeper store ->
    Fs_compat.subdirectory_names keepers
    |> List.concat_map (fun keeper_name ->
      existing (keeper root ~keeper:keeper_name store))
  | Reaction_ledger ->
    Fs_compat.subdirectory_names keepers
    |> List.concat_map (fun keeper_name ->
      let ledger =
        List.fold_left
          Filename.concat
          keepers
          [ keeper_name
          ; Common.keeper_runtime_store_dirname Common.Keeper_reaction_ledger
          ]
      in
      Fs_compat.subdirectory_names ledger
      |> List.map (fun generation -> reaction_ledger root ~keeper:keeper_name ~generation))
  | Decision_audit ->
    Fs_compat.subdirectory_names (Filename.concat dir decision_audit_dirname)
    |> List.map (fun keeper_dirname -> decision_audit root ~keeper_dirname)

let with_retention_root (Masc_dir dir) f =
  (* BasePath admission allows aliases, including macOS /var and /tmp.
     Resolve that trusted base only; the runtime root and every descendant
     are subsequently opened no-follow from held descriptors. *)
  match Fs_compat.realpath (Filename.dirname dir) with
  | base -> Fs_compat.Retention_directory.with_root
      (Filename.concat base (Filename.basename dir)) f
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None

let with_retention_location location f =
  match with_retention_root (Masc_dir location.root) (fun root ->
    Fs_compat.Retention_directory.descend root location.segments f) with
  | None -> 0
  | Some result -> result

let fold_retention_directories root held store ~f =
  let module Directory = Fs_compat.Retention_directory in
  let keepers f =
    Directory.descend held [ Common.keepers_runtime_dirname ] (fun directory ->
      Directory.fold_children directory ~init:0
        ~f:(fun count name child -> count + f name child)) in
  match store with
  | Root store -> Directory.descend held (Root.segments store) (f (at root store))
  | Keeper store -> keepers (fun name child ->
      Directory.descend child [ Keeper.dirname store ] (f (keeper root ~keeper:name store)))
  | Reaction_ledger -> keepers (fun name child ->
      Directory.descend child
        [ Common.keeper_runtime_store_dirname Common.Keeper_reaction_ledger ]
        (fun ledger -> Directory.fold_children ledger ~init:0
          ~f:(fun count generation directory ->
            count + f (reaction_ledger root ~keeper:name ~generation) directory)))
  | Decision_audit ->
    Directory.descend held [ decision_audit_dirname ] (fun directory ->
      Directory.fold_children directory ~init:0
        ~f:(fun count name child -> count + f (decision_audit root ~keeper_dirname:name) child))

type dated_path =
  { base_dir : string
  ; month_dir : string
  ; day_file : string
  ; path : string
  }

let dated_path location ~ts =
  let year, month, day = Jsonl_writer.utc_calendar_day ~ts in
  let month_dir = Printf.sprintf "%04d-%02d" year month in
  let day_file = Printf.sprintf "%02d.jsonl" day in
  let path = Filename.concat (Filename.concat location.dir month_dir) day_file in
  { base_dir = location.dir; month_dir; day_file; path }

let dated_path_now location =
  (* NDT-OK: this is the runtime write boundary for date-split JSONL;
     deterministic callers use [dated_path ~ts] with an explicit timestamp. *)
  dated_path location ~ts:(Unix.gettimeofday ())
