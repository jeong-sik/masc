(** [Dated_jsonl.Store]: where each listed store lives, and that a store
    opened through the list writes there. *)

open Alcotest
module Store = Dated_jsonl.Store

let base_path = "/ws"
let cluster_root = Store.cluster_root "/ws/.masc/clusters/east"
let keeper = "alice"
let generation = "v7"

let location = function
  | Store.Base store -> Store.base ~base_path store
  | Store.Cluster store -> Store.cluster cluster_root store
  | Store.Keeper store -> Store.keeper cluster_root ~keeper store
  | Store.Reaction_ledger -> Store.reaction_ledger ~base_path ~keeper ~generation
  | Store.Decision_audit -> Store.decision_audit ~base_path ~keeper_dirname:keeper
;;

(* Written out per store on purpose: these are directories that hold data on
   disk, so a rename has to show up here as a changed line. A new store does
   not compile until its directory is added. *)
let expected_dir = function
  | Store.Base Transition_audit -> "/ws/.masc/transition-audit"
  | Store.Base Audit_approvals -> "/ws/.masc/audit-approvals"
  | Store.Base Tool_events -> "/ws/.masc/tool-events"
  | Store.Base Keeper_wake_payload -> "/ws/.masc/keeper-wake-payload"
  | Store.Base Verdicts -> "/ws/.masc/verdicts"
  | Store.Cluster Audit -> "/ws/.masc/clusters/east/audit"
  | Store.Cluster Telemetry -> "/ws/.masc/clusters/east/telemetry"
  | Store.Cluster Events -> "/ws/.masc/clusters/east/events"
  | Store.Cluster Activity_events -> "/ws/.masc/clusters/east/activity-events"
  | Store.Cluster Tool_calls -> "/ws/.masc/clusters/east/tool_calls"
  | Store.Cluster Tool_usage -> "/ws/.masc/clusters/east/tool_usage"
  | Store.Cluster Agent_core_events -> "/ws/.masc/clusters/east/agent-core-events"
  | Store.Cluster Costs -> "/ws/.masc/clusters/east/costs"
  | Store.Cluster Provider_usage_history ->
    "/ws/.masc/clusters/east/provider_usage_history"
  | Store.Cluster Wire_capture -> "/ws/.masc/clusters/east/wire-capture"
  | Store.Cluster Schedule_signals -> "/ws/.masc/clusters/east/schedules/signals"
  | Store.Cluster Telemetry_coverage_gaps ->
    "/ws/.masc/clusters/east/telemetry-coverage-gaps"
  | Store.Keeper Metrics -> "/ws/.masc/clusters/east/keepers/alice/metrics"
  | Store.Keeper Execution_receipts ->
    "/ws/.masc/clusters/east/keepers/alice/execution-receipts"
  | Store.Keeper Turn_records -> "/ws/.masc/clusters/east/keepers/alice/turn-records"
  | Store.Keeper Provider_inputs ->
    "/ws/.masc/clusters/east/keepers/alice/provider-inputs"
  | Store.Keeper Memory_recall_artifacts ->
    "/ws/.masc/clusters/east/keepers/alice/memory-recall-artifacts"
  | Store.Keeper Crash_events -> "/ws/.masc/clusters/east/keepers/alice/crash-events"
  | Store.Keeper Continuity_requests ->
    "/ws/.masc/clusters/east/keepers/alice/continuity-requests"
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

(* In the default cluster the cluster root is the base root, so every store
   is under [<base>/.masc]. *)
let test_default_cluster_keeps_every_store_under_the_base_root () =
  let default_root = Store.cluster_root "/ws/.masc" in
  check
    string
    "base store"
    "/ws/.masc/verdicts"
    (Store.dir (Store.base ~base_path Verdicts));
  check
    string
    "cluster store"
    "/ws/.masc/audit"
    (Store.dir (Store.cluster default_root Audit));
  check
    string
    "keeper store"
    "/ws/.masc/keepers/alice/metrics"
    (Store.dir (Store.keeper default_root ~keeper Metrics))
;;

let test_dated_path_names_the_day_file_under_the_store () =
  let location = Store.cluster cluster_root Audit in
  let dated = Store.dated_path location ~ts:0. in
  check string "day file" "/ws/.masc/clusters/east/audit/1970-01/01.jsonl" dated.path
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
  let location = Store.base ~base_path Verdicts in
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
  | Store.Base Transition_audit -> Window
  | Store.Base Audit_approvals -> Window
  | Store.Base Tool_events -> Window
  | Store.Base Keeper_wake_payload -> Window
  | Store.Base Verdicts -> Never
  | Store.Cluster Audit -> Window
  | Store.Cluster Telemetry -> Window
  | Store.Cluster Events -> Window
  | Store.Cluster Activity_events -> Window
  | Store.Cluster Tool_calls -> Window
  | Store.Cluster Tool_usage -> Window
  | Store.Cluster Agent_core_events -> Window
  | Store.Cluster Costs -> Window
  | Store.Cluster Provider_usage_history -> Days 16
  | Store.Cluster Wire_capture -> Setting
  | Store.Cluster Schedule_signals -> Window
  | Store.Cluster Telemetry_coverage_gaps -> Window
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

(* One temporary workspace whose cluster is not the default one, so a store
   pruned under the wrong root keeps its file. *)
let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = tmpdir () in
  let cluster_root =
    Store.cluster_root (List.fold_left Filename.concat base_path [ ".masc"; "clusters"; "east" ])
  in
  f ~base_path ~cluster_root
;;

let location_in ~base_path ~cluster_root = function
  | Store.Base store -> Store.base ~base_path store
  | Store.Cluster store -> Store.cluster cluster_root store
  | Store.Keeper store -> Store.keeper cluster_root ~keeper store
  | Store.Reaction_ledger -> Store.reaction_ledger ~base_path ~keeper ~generation
  | Store.Decision_audit -> Store.decision_audit ~base_path ~keeper_dirname:keeper
;;

let write_day_file location ~age_days =
  let ts = Unix.gettimeofday () -. (float_of_int age_days *. day) in
  let dated = Store.dated_path location ~ts in
  Fs_compat.mkdir_p (Filename.dirname dated.path);
  Out_channel.with_open_text dated.path (fun oc -> output_string oc "{}\n");
  dated.path
;;

(* A day file [age_days] old in every store, keyed by the store. *)
let write_every_store ~base_path ~cluster_root ~age_days =
  List.map
    (fun store ->
       store, write_day_file (location_in ~base_path ~cluster_root store) ~age_days)
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
  @@ fun ~base_path ~cluster_root ->
  let old = write_every_store ~base_path ~cluster_root ~age_days:400 in
  let today = write_every_store ~base_path ~cluster_root ~age_days:0 in
  ignore
    (Dated_jsonl.prune_listed_stores ~base_path cluster_root ~operator_window_days:30
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
  @@ fun ~base_path ~cluster_root ->
  let old = write_every_store ~base_path ~cluster_root ~age_days:400 in
  ignore
    (Dated_jsonl.prune_listed_stores ~base_path cluster_root ~operator_window_days:0
     : int);
  check_files ~label:"old" old ~removed:(fun store ->
    match expected_rule store with
    | Days _ | Setting -> true
    | Window | Never -> false)
;;

let test_fixed_days_ignore_the_window () =
  with_workspace
  @@ fun ~base_path ~cluster_root ->
  let location = Store.cluster cluster_root Provider_usage_history in
  let twenty = write_day_file location ~age_days:20 in
  let ten = write_day_file location ~age_days:10 in
  ignore
    (Dated_jsonl.prune_listed_stores ~base_path cluster_root ~operator_window_days:7
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
  @@ fun ~base_path ~cluster_root ->
  let five = write_day_file (Store.cluster cluster_root Wire_capture) ~age_days:5 in
  let prune () =
    ignore
      (Dated_jsonl.prune_listed_stores ~base_path cluster_root ~operator_window_days:30
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
  @@ fun ~base_path ~cluster_root ->
  let keepers = [ "alice"; "bob" ] in
  let metrics =
    List.map
      (fun keeper -> write_day_file (Store.keeper cluster_root ~keeper Metrics) ~age_days:400)
      keepers
  in
  let ledgers =
    List.concat_map
      (fun keeper ->
         List.map
           (fun generation ->
              write_day_file (Store.reaction_ledger ~base_path ~keeper ~generation) ~age_days:400)
           [ "v6"; "v7" ])
      keepers
  in
  let decisions =
    List.map
      (fun keeper_dirname ->
         write_day_file (Store.decision_audit ~base_path ~keeper_dirname) ~age_days:400)
      keepers
  in
  let stray =
    Filename.concat
      (Filename.dirname
         (Filename.dirname (Store.dir (Store.keeper cluster_root ~keeper:"alice" Metrics))))
      "stray.txt"
  in
  Out_channel.with_open_text stray (fun oc -> output_string oc "x");
  let pruned =
    Dated_jsonl.prune_listed_stores ~base_path cluster_root ~operator_window_days:30
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
  @@ fun ~base_path ~cluster_root ->
  let metrics = write_day_file (Store.keeper cluster_root ~keeper:"alice" Metrics) ~age_days:400 in
  let decision =
    write_day_file (Store.decision_audit ~base_path ~keeper_dirname:"alice") ~age_days:400
  in
  let keepers_dir =
    Filename.dirname
      (Filename.dirname (Store.dir (Store.keeper cluster_root ~keeper:"alice" Metrics)))
  in
  let decision_dir = Filename.dirname (Store.dir (Store.decision_audit ~base_path ~keeper_dirname:"alice")) in
  Unix.symlink (Filename.concat keepers_dir "gone") (Filename.concat keepers_dir "ghost");
  Unix.symlink (Filename.concat decision_dir "gone") (Filename.concat decision_dir "ghost");
  let pruned =
    Dated_jsonl.prune_listed_stores ~base_path cluster_root ~operator_window_days:30
  in
  check int "both old files counted" 2 pruned;
  check bool "keeper store pruned" false (Sys.file_exists metrics);
  check bool "decision audit pruned" false (Sys.file_exists decision)
;;

let test_a_missing_store_counts_nothing () =
  with_workspace
  @@ fun ~base_path ~cluster_root ->
  check
    int
    "empty workspace"
    0
    (Dated_jsonl.prune_listed_stores ~base_path cluster_root ~operator_window_days:30)
;;

let () =
  run
    "dated_jsonl_store"
    [ ( "layout"
      , [ test_case "every store has its directory" `Quick
            test_every_store_has_its_directory
        ; test_case "no two stores share a directory" `Quick
            test_no_two_stores_share_a_directory
        ; test_case "default cluster keeps every store under the base root" `Quick
            test_default_cluster_keeps_every_store_under_the_base_root
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
