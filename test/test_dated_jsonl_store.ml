(** [Dated_jsonl.Store]: where each listed store lives, and that a store
    opened through the list writes there. *)

open Alcotest
module Store = Dated_jsonl.Store

let root = Store.root_of_base_path ~base_path:"/ws"
let keeper = "alice"
let generation = "v7"

let location_at root = function
  | Store.Root store -> Store.at root store
  | Store.Keeper store -> Store.keeper root ~keeper store
  | Store.Reaction_ledger -> Store.reaction_ledger root ~keeper ~generation
  | Store.Decision_audit -> Store.decision_audit root ~keeper_dirname:keeper
;;

let location = location_at root

(* Written out per store on purpose: these are directories that hold data on
   disk, so a rename has to show up here as a changed line. A new store does
   not compile until its directory is added. *)
let expected_dir = function
  | Store.Root Transition_audit -> "/ws/.masc/transition-audit"
  | Store.Root Audit_approvals -> "/ws/.masc/audit-approvals"
  | Store.Root Tool_events -> "/ws/.masc/tool-events"
  | Store.Root Keeper_wake_payload -> "/ws/.masc/keeper-wake-payload"
  | Store.Root Verdicts -> "/ws/.masc/verdicts"
  | Store.Root Audit -> "/ws/.masc/audit"
  | Store.Root Telemetry -> "/ws/.masc/telemetry"
  | Store.Root Events -> "/ws/.masc/events"
  | Store.Root Activity_events -> "/ws/.masc/activity-events"
  | Store.Root Tool_calls -> "/ws/.masc/tool_calls"
  | Store.Root Tool_usage -> "/ws/.masc/tool_usage"
  | Store.Root Agent_core_events -> "/ws/.masc/agent-core-events"
  | Store.Root Costs -> "/ws/.masc/costs"
  | Store.Root Provider_usage_history -> "/ws/.masc/provider_usage_history"
  | Store.Root Wire_capture -> "/ws/.masc/wire-capture"
  | Store.Root Schedule_signals -> "/ws/.masc/schedules/signals"
  | Store.Root Telemetry_coverage_gaps -> "/ws/.masc/telemetry-coverage-gaps"
  | Store.Keeper Metrics -> "/ws/.masc/keepers/alice/metrics"
  | Store.Keeper Execution_receipts -> "/ws/.masc/keepers/alice/execution-receipts"
  | Store.Keeper Turn_records -> "/ws/.masc/keepers/alice/turn-records"
  | Store.Keeper Provider_inputs -> "/ws/.masc/keepers/alice/provider-inputs"
  | Store.Keeper Memory_recall_artifacts ->
    "/ws/.masc/keepers/alice/memory-recall-artifacts"
  | Store.Keeper Crash_events -> "/ws/.masc/keepers/alice/crash-events"
  | Store.Keeper Continuity_requests -> "/ws/.masc/keepers/alice/continuity-requests"
  | Store.Reaction_ledger -> "/ws/.masc/keepers/alice/reaction-ledger/v7"
  | Store.Decision_audit -> "/ws/.masc/decision_audit/alice"
;;

let test_every_store_has_its_directory () =
  List.iter
    (fun store ->
       let expected = expected_dir store in
       check string expected expected (Store.dir (location store)))
    Store.all
;;

let test_no_two_stores_share_a_directory () =
  let dirs = List.map (fun store -> Store.dir (location store)) Store.all in
  check
    int
    "distinct directories"
    (List.length dirs)
    (List.length (List.sort_uniq String.compare dirs))
;;

(* RFC-0474 L4c. A pool job that reads a store is named by it: the name
   tells the store apart from every other store and does not carry the keeper,
   so one keeper store across forty keepers is one name. *)
let test_a_location_knows_its_store_and_its_job_name () =
  List.iter
    (fun store ->
       let name = Store.pool_job_name store in
       check string name name (Store.pool_job_name (Store.of_location (location store)));
       check bool (name ^ " does not name the keeper") false
         (String.split_on_char '/' name |> List.mem keeper))
    Store.all;
  let names = List.map Store.pool_job_name Store.all in
  check int "distinct job names" (List.length names)
    (List.length (List.sort_uniq String.compare names))
;;

(* A caller holding the [.masc] directory and one holding the base path name
   the same root. *)
let test_both_roots_name_the_same_directories () =
  let from_masc_dir = location_at (Store.root_of_masc_dir "/ws/.masc") in
  List.iter
    (fun store ->
       check string (expected_dir store) (Store.dir (location store))
         (Store.dir (from_masc_dir store)))
    Store.all
;;

let test_dated_path_names_the_day_file_under_the_store () =
  let location = Store.at root Audit in
  let dated = Store.dated_path location ~ts:0. in
  check string "day file" "/ws/.masc/audit/1970-01/01.jsonl" dated.path
;;

let tmp_counter = ref 0

let tmpdir () =
  incr tmp_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "dated_store_%d_%d_%.0f" !tmp_counter (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let test_an_opened_store_appends_under_its_location () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = tmpdir () in
  let location = Store.at (Store.root_of_base_path ~base_path) Verdicts in
  let store = Dated_jsonl.open_store location in
  Dated_jsonl.append store (`Assoc [ "n", `Int 1 ]);
  let day_file = (Store.dated_path_now location).path in
  check bool "day file exists" true (Sys.file_exists day_file);
  check
    string
    "under the listed directory"
    (Filename.concat base_path ".masc/verdicts")
    (Filename.dirname (Filename.dirname day_file));
  check int "one row" 1 (List.length (Dated_jsonl.read_recent store 10))
;;

(* The rule each store is kept by, written out per store: which records are
   removed by date is an operator decision (RFC
   dated-stores-take-retention-from-one-list §4.4, §9), so a changed rule has
   to show up here as a changed line. *)
type expected_rule =
  | Window
  | Days of int
  | Setting
  | Never

let expected_rule = function
  | Store.Root Transition_audit -> Window
  | Store.Root Audit_approvals -> Window
  | Store.Root Tool_events -> Window
  | Store.Root Keeper_wake_payload -> Window
  | Store.Root Verdicts -> Never
  | Store.Root Audit -> Window
  | Store.Root Telemetry -> Window
  | Store.Root Events -> Window
  | Store.Root Activity_events -> Window
  | Store.Root Tool_calls -> Window
  | Store.Root Tool_usage -> Window
  | Store.Root Agent_core_events -> Window
  | Store.Root Costs -> Window
  | Store.Root Provider_usage_history -> Days 16
  | Store.Root Wire_capture -> Setting
  | Store.Root Schedule_signals -> Window
  | Store.Root Telemetry_coverage_gaps -> Window
  | Store.Keeper Metrics -> Window
  | Store.Keeper Execution_receipts -> Window
  | Store.Keeper Turn_records -> Window
  | Store.Keeper Provider_inputs -> Window
  | Store.Keeper Memory_recall_artifacts -> Window
  | Store.Keeper Crash_events -> Window
  | Store.Keeper Continuity_requests -> Window
  | Store.Reaction_ledger -> Window
  | Store.Decision_audit -> Window
;;

let test_every_store_has_its_rule () =
  List.iter
    (fun store ->
       let label = Store.dir (location store) in
       match expected_rule store, Store.retention store with
       | Window, Store.Operator_window
       | Setting, Store.Own_days _
       | Never, Store.Kept -> ()
       | Days expected, Store.Fixed_days days -> check int label expected days
       | (Window | Days _ | Setting | Never), _ -> fail ("unexpected rule for " ^ label))
    Store.all
;;

let day = 86_400.

(* One temporary workspace. *)
let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f (Store.root_of_base_path ~base_path:(tmpdir ()))
;;

let write_day_file location ~age_days =
  let ts = Unix.gettimeofday () -. (float_of_int age_days *. day) in
  let dated = Store.dated_path location ~ts in
  Fs_compat.mkdir_p (Filename.dirname dated.path);
  Out_channel.with_open_text dated.path (fun oc -> output_string oc "{}\n");
  dated.path
;;

(* A day file [age_days] old in every store, keyed by the store. *)
let write_every_store root ~age_days =
  List.map
    (fun store ->
       store, write_day_file (location_at root store) ~age_days)
    Store.all
;;

let check_files ~label ~removed files =
  List.iter
    (fun (store, path) ->
       check bool (label ^ " " ^ path) (removed store) (not (Sys.file_exists path)))
    files
;;

let test_old_files_go_by_each_stores_rule () =
  with_workspace
  @@ fun root ->
  let old = write_every_store root ~age_days:400 in
  let today = write_every_store root ~age_days:0 in
  ignore
    (Dated_jsonl.prune_listed_stores root ~operator_window_days:30
     : int);
  check_files ~label:"old" old ~removed:(fun store ->
    match expected_rule store with
    | Window | Days _ | Setting -> true
    | Never -> false);
  check_files ~label:"today" today ~removed:(fun _ -> false)
;;

(* A window of zero keeps the window's stores whole. The stores with their
   own number still lose old files. *)
let test_a_zero_window_keeps_only_the_windows_stores () =
  with_workspace
  @@ fun root ->
  let old = write_every_store root ~age_days:400 in
  ignore
    (Dated_jsonl.prune_listed_stores root ~operator_window_days:0
     : int);
  check_files ~label:"old" old ~removed:(fun store ->
    match expected_rule store with
    | Days _ | Setting -> true
    | Window | Never -> false)
;;

let test_fixed_days_ignore_the_window () =
  with_workspace
  @@ fun root ->
  let location = Store.at root Provider_usage_history in
  let twenty = write_day_file location ~age_days:20 in
  let ten = write_day_file location ~age_days:10 in
  ignore
    (Dated_jsonl.prune_listed_stores root ~operator_window_days:7
     : int);
  check bool "20 days old is removed" false (Sys.file_exists twenty);
  check bool "10 days old stays under a 7-day window" true (Sys.file_exists ten)
;;

let with_env name value f =
  let prior = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value prior ~default:""))
    f
;;

(* The wire capture's own setting is read each time the pass runs, not when
   a handle was opened. *)
let test_own_days_are_read_at_each_pass () =
  with_workspace
  @@ fun root ->
  let five = write_day_file (Store.at root Wire_capture) ~age_days:5 in
  let prune () =
    ignore
      (Dated_jsonl.prune_listed_stores root ~operator_window_days:30
       : int)
  in
  with_env "MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS" "10" prune;
  check bool "kept under 10 days" true (Sys.file_exists five);
  with_env "MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS" "2" prune;
  check bool "removed under 2 days" false (Sys.file_exists five)
;;

(* Per-keeper stores are found from the directories on disk, so a keeper
   that is no longer declared still loses its old files. A stray file beside
   the keeper directories is not a keeper. *)
let test_every_keeper_directory_on_disk_is_pruned () =
  with_workspace
  @@ fun root ->
  let keepers = [ "alice"; "bob" ] in
  let metrics =
    List.map
      (fun keeper -> write_day_file (Store.keeper root ~keeper Metrics) ~age_days:400)
      keepers
  in
  let ledgers =
    List.concat_map
      (fun keeper ->
         List.map
           (fun generation ->
              write_day_file (Store.reaction_ledger root ~keeper ~generation) ~age_days:400)
           [ "v6"; "v7" ])
      keepers
  in
  let decisions =
    List.map
      (fun keeper_dirname ->
         write_day_file (Store.decision_audit root ~keeper_dirname) ~age_days:400)
      keepers
  in
  let stray =
    Filename.concat
      (Filename.dirname
         (Filename.dirname (Store.dir (Store.keeper root ~keeper:"alice" Metrics))))
      "stray.txt"
  in
  Out_channel.with_open_text stray (fun oc -> output_string oc "x");
  let pruned =
    Dated_jsonl.prune_listed_stores root ~operator_window_days:30
  in
  check int "every old file counted" 8 pruned;
  List.iter
    (fun path -> check bool path false (Sys.file_exists path))
    (metrics @ ledgers @ decisions);
  check bool "stray file untouched" true (Sys.file_exists stray)
;;

(* A keeper folder that is a broken link, or that disappears while the pass
   reads the folder list, is not a keeper. It does not stop the stores after
   it from being pruned (#42891). *)
let test_a_broken_keeper_link_does_not_stop_the_pass () =
  with_workspace
  @@ fun root ->
  let metrics = write_day_file (Store.keeper root ~keeper:"alice" Metrics) ~age_days:400 in
  let decision =
    write_day_file (Store.decision_audit root ~keeper_dirname:"alice") ~age_days:400
  in
  let keepers_dir =
    Filename.dirname
      (Filename.dirname (Store.dir (Store.keeper root ~keeper:"alice" Metrics)))
  in
  let decision_dir = Filename.dirname (Store.dir (Store.decision_audit root ~keeper_dirname:"alice")) in
  Unix.symlink (Filename.concat keepers_dir "gone") (Filename.concat keepers_dir "ghost");
  Unix.symlink (Filename.concat decision_dir "gone") (Filename.concat decision_dir "ghost");
  let pruned =
    Dated_jsonl.prune_listed_stores root ~operator_window_days:30
  in
  check int "both old files counted" 2 pruned;
  check bool "keeper store pruned" false (Sys.file_exists metrics);
  check bool "decision audit pruned" false (Sys.file_exists decision)
;;

let test_a_missing_store_counts_nothing () =
  with_workspace
  @@ fun root ->
  check
    int
    "empty workspace"
    0
    (Dated_jsonl.prune_listed_stores root ~operator_window_days:30)
;;

let () =
  run
    "dated_jsonl_store"
    [ ( "layout"
      , [ test_case "every store has its directory" `Quick
            test_every_store_has_its_directory
        ; test_case "no two stores share a directory" `Quick
            test_no_two_stores_share_a_directory
        ; test_case "a location knows its store and its job name" `Quick
            test_a_location_knows_its_store_and_its_job_name
        ; test_case "both roots name the same directories" `Quick
            test_both_roots_name_the_same_directories
        ; test_case "dated path names the day file under the store" `Quick
            test_dated_path_names_the_day_file_under_the_store
        ] )
    ; ( "open"
      , [ test_case "an opened store appends under its location" `Quick
            test_an_opened_store_appends_under_its_location
        ] )
    ; ( "retention"
      , [ test_case "every store has its rule" `Quick test_every_store_has_its_rule
        ; test_case "old files go by each store's rule" `Quick
            test_old_files_go_by_each_stores_rule
        ; test_case "a zero window keeps only the window's stores" `Quick
            test_a_zero_window_keeps_only_the_windows_stores
        ; test_case "fixed days ignore the window" `Quick
            test_fixed_days_ignore_the_window
        ; test_case "own days are read at each pass" `Quick
            test_own_days_are_read_at_each_pass
        ; test_case "every keeper directory on disk is pruned" `Quick
            test_every_keeper_directory_on_disk_is_pruned
        ; test_case "a broken keeper link does not stop the pass" `Quick
            test_a_broken_keeper_link_does_not_stop_the_pass
        ; test_case "a missing store counts nothing" `Quick
            test_a_missing_store_counts_nothing
        ] )
    ]
;;
