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
    ]
;;
