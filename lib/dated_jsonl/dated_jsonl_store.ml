module Root = struct
  type t =
    | Transition_audit
    | Audit_approvals
    | Tool_events
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

type location =
  { store : t
  ; dir : string
  ; root : string
  ; segments : string list
  ; keeper_store : (string * Keeper.t) option
  }
type root = Masc_dir of string

let root_of_base_path ~base_path = Masc_dir (Common.masc_dir_from_base_path ~base_path)
let root_of_masc_dir dir = Masc_dir dir
let under ?keeper_store (Masc_dir root) store segments =
  { store; dir = List.fold_left Filename.concat root segments; root; segments; keeper_store }
let at root store = under root (Root store) (Root.segments store)

let keeper root ~keeper store =
  under ~keeper_store:(keeper, store) root (Keeper store)
    [ Common.keepers_runtime_dirname; keeper; Keeper.dirname store ]

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

let absolute_dir location =
  if Filename.is_relative location.dir
  then Filename.concat (Config_dir_resolver.current_working_dir ()) location.dir
  else location.dir

let of_location location = location.store
let keeper_store location = location.keeper_store

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

type facts =
  | Kept_by_the_lease_holder
  | Read_from_the_files

(* Who changes a store's files. [Kept_by_the_lease_holder] says that every
   change is made by the process that holds the workspace's writer lease, and
   is written here once the store's writers have been gone through. A store
   nobody has gone through is read from the files, and so is one that
   another process is known to write. *)
let root_facts = function
  (* [masc-cost --log] appends to the cost log and takes no lease
     ([bin/masc_cost.ml]). *)
  | Root.Costs -> Read_from_the_files
  (* One writer, [Keeper_tool_call_log], and only in a process where the
     server's start has opened the ledger ([Server_bootstrap_maintenance]),
     which holds the lease; anywhere else a logged call writes nothing. The
     read index keeps its own files beside the months and changes no day
     file. Day files go by the prune pass, in that process. *)
  | Root.Tool_calls -> Kept_by_the_lease_holder
  | Root.Transition_audit
  | Root.Audit_approvals
  | Root.Tool_events
  | Root.Verdicts
  | Root.Audit
  | Root.Telemetry
  | Root.Events
  | Root.Activity_events
  | Root.Tool_usage
  | Root.Agent_core_events
  | Root.Provider_usage_history
  | Root.Wire_capture
  | Root.Schedule_signals
  | Root.Telemetry_coverage_gaps -> Read_from_the_files

let keeper_facts = function
  (* One writer, [Keeper_turn_record_writer], called from the Keeper's turn.
     A turn runs only in a process that holds the lease. Day files go by the
     prune pass and by the Keeper's purge, both in that process. *)
  | Keeper.Turn_records -> Kept_by_the_lease_holder
  (* One writer, [Keeper_execution_receipt.append], called when a Keeper's
     run ends; a run is in a process that holds the lease. Day files go by
     the prune pass and by the Keeper's purge, both in that process. Boot
     reconcile does not move this store. *)
  | Keeper.Execution_receipts -> Kept_by_the_lease_holder
  (* One writer, [Keeper_types_support.append_keeper_metrics], with two
     callers: the row a Keeper's turn ends with and the row of its heartbeat
     loop. Both run only in a process that holds the lease. The append
     rotates the day file by size and prunes to the store's byte budget
     itself. Day files also go by the prune pass and by the Keeper's purge,
     both in that process. No command line tool appends to this store. *)
  | Keeper.Metrics -> Kept_by_the_lease_holder
  | Keeper.Provider_inputs
  | Keeper.Memory_recall_artifacts
  | Keeper.Crash_events
  | Keeper.Continuity_requests -> Read_from_the_files

let facts = function
  | Root store -> root_facts store
  | Keeper store -> keeper_facts store
  | Reaction_ledger | Decision_audit -> Read_from_the_files

(* What a store's owner keeps in the store's own directory, beside the month
   directories: a file made from the day files, which no reader of the day
   files reads. Each store answers for itself, so a new store has to.

   The activity events keep [_seq] there and do not say so here. The one
   strict reader of that store, the task history inventory, passes over it
   in its own listing. *)
let root_side_file store name =
  match store with
  (* The SQLite read index of [Keeper_tool_call_index] and its sidecars. *)
  | Root.Tool_calls -> Common.is_tool_call_read_index_file name
  | Root.Transition_audit
  | Root.Audit_approvals
  | Root.Tool_events
  | Root.Verdicts
  | Root.Audit
  | Root.Telemetry
  | Root.Events
  | Root.Activity_events
  | Root.Tool_usage
  | Root.Agent_core_events
  | Root.Costs
  | Root.Provider_usage_history
  | Root.Wire_capture
  | Root.Schedule_signals
  | Root.Telemetry_coverage_gaps -> false

let keeper_side_file store (_ : string) =
  match store with
  | Keeper.Metrics
  | Keeper.Execution_receipts
  | Keeper.Turn_records
  | Keeper.Provider_inputs
  | Keeper.Memory_recall_artifacts
  | Keeper.Crash_events
  | Keeper.Continuity_requests -> false

let is_side_file store name =
  match store with
  | Root store -> root_side_file store name
  | Keeper store -> keeper_side_file store name
  | Reaction_ledger | Decision_audit -> false

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

let fold_keeper_retention_directories
      root
      held
      ~keeper_stores
      ~reaction_ledger:reaction_ledger_arg
      ~f
  =
  if keeper_stores = [] && Option.is_none reaction_ledger_arg
  then 0
  else
    let module Directory = Fs_compat.Retention_directory in
    let reaction_ledger_dir =
      Common.keeper_runtime_store_dirname Common.Keeper_reaction_ledger
    in
    Directory.descend held [ Common.keepers_runtime_dirname ] (fun keepers_dir ->
      Directory.fold_children keepers_dir ~init:0 ~f:(fun count keeper_name keeper_dir ->
        let present = Directory.names keeper_dir in
        let count =
          List.fold_left
            (fun acc (store, arg) ->
               let dirname = Keeper.dirname store in
               if List.mem dirname present
               then
                 acc
                 + Directory.descend keeper_dir [ dirname ]
                     (f arg (keeper root ~keeper:keeper_name store))
               else acc)
            count
            keeper_stores
        in
        match reaction_ledger_arg with
        | Some arg when List.mem reaction_ledger_dir present ->
          count
          + Directory.descend keeper_dir [ reaction_ledger_dir ] (fun ledger ->
              Directory.fold_children ledger ~init:0 ~f:(fun acc generation directory ->
                acc + f arg (reaction_ledger root ~keeper:keeper_name ~generation) directory))
        | Some _ | None -> count))

type dated_path =
  { base_dir : string
  ; month_dir : string
  ; day_file : string
  ; path : string
  }

let dated_path location ~ts =
  let year, month, day = Jsonl_writer.utc_calendar_day ~ts in
  let month_dir =
    if year >= 0 && year <= 9999 then begin
      let b = Bytes.create 7 in
      let yq = year / 100 in
      let yr = year - (yq * 100) in
      Bytes.unsafe_set b 0 (Char.unsafe_chr (48 + (yq / 10)));
      Bytes.unsafe_set b 1 (Char.unsafe_chr (48 + (yq mod 10)));
      Bytes.unsafe_set b 2 (Char.unsafe_chr (48 + (yr / 10)));
      Bytes.unsafe_set b 3 (Char.unsafe_chr (48 + (yr mod 10)));
      Bytes.unsafe_set b 4 '-';
      Bytes.unsafe_set b 5 (Char.unsafe_chr (48 + (month / 10)));
      Bytes.unsafe_set b 6 (Char.unsafe_chr (48 + (month mod 10)));
      Bytes.unsafe_to_string b
    end else
      Printf.sprintf "%04d-%02d" year month
  in
  let day_file =
    if day >= 0 && day <= 99 then begin
      let b = Bytes.create 8 in
      Bytes.unsafe_set b 0 (Char.unsafe_chr (48 + (day / 10)));
      Bytes.unsafe_set b 1 (Char.unsafe_chr (48 + (day mod 10)));
      Bytes.blit_string ".jsonl" 0 b 2 6;
      Bytes.unsafe_to_string b
    end else
      Printf.sprintf "%02d.jsonl" day
  in
  let path = Filename.concat (Filename.concat location.dir month_dir) day_file in
  { base_dir = location.dir; month_dir; day_file; path }

let dated_path_now location =
  (* NDT-OK: this is the runtime write boundary for date-split JSONL;
     deterministic callers use [dated_path ~ts] with an explicit timestamp. *)
  dated_path location ~ts:(Unix.gettimeofday ())
