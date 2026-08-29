(** Unit tests for [Server_runtime_startup_maintenance] prune folds. *)

module SM = Server_runtime_startup_maintenance

let counter = ref 0

let fresh_dir prefix =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%.0f" prefix (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir

let record_prune dir =
  incr counter;
  String.length dir

let test_missing_root_counts_zero () =
  counter := 0;
  let n =
    SM.prune_children_dirs ~prune_dir:record_prune "/nonexistent/masc-prune-children"
  in
  Alcotest.(check int) "missing root counts 0" 0 n;
  Alcotest.(check int) "prune_dir never called" 0 !counter

let test_subdirs_pruned_and_stray_files_skipped () =
  counter := 0;
  let root = fresh_dir "masc_prune_children" in
  let keeper_a = Filename.concat root "keeper-a" in
  let keeper_b = Filename.concat root "keeper-b" in
  Fs_compat.mkdir_p keeper_a;
  Fs_compat.mkdir_p keeper_b;
  let stray = Filename.concat root "stray.txt" in
  let oc = open_out stray in
  output_string oc "x";
  close_out oc;
  let n = SM.prune_children_dirs ~prune_dir:record_prune root in
  Alcotest.(check int) "prune called for both subdirs" 2 !counter;
  Alcotest.(check bool)
    "return sums prune_dir results" true (n = String.length keeper_a + String.length keeper_b)

let test_prune_flat_jsonl_removes_old_files () =
  (* Regression guard for the trajectories no-op: populated
     trajectories/<keeper>/ layout must yield pruned > 0. *)
  let root = fresh_dir "masc_prune_flat" in
  let keeper = Filename.concat root "keeper-a" in
  Fs_compat.mkdir_p keeper;
  let write path =
    let oc = open_out path in
    output_string oc "{}\n";
    close_out oc
  in
  let old_file = Filename.concat keeper "trace-old.jsonl" in
  let recent_file = Filename.concat keeper "trace-recent.jsonl" in
  let stray = Filename.concat keeper "notes.txt" in
  write old_file;
  write recent_file;
  write stray;
  let old_ts = Unix.gettimeofday () -. (40. *. 86400.) in
  Unix.utimes old_file old_ts old_ts;
  let n =
    SM.prune_children_dirs
      ~prune_dir:(SM.prune_flat_jsonl_older_than ~days:30)
      root
  in
  Alcotest.(check int) "old trajectory pruned" 1 n;
  Alcotest.(check bool) "old file removed" false (Sys.file_exists old_file);
  Alcotest.(check bool) "recent file kept" true (Sys.file_exists recent_file);
  Alcotest.(check bool) "non-jsonl file kept" true (Sys.file_exists stray)

let visited = ref []

let record_visit dir =
  visited := dir :: !visited;
  0

let test_keeper_scoped_store_list_is_ssot () =
  (* Drift guard: the 24h periodic pass used to prune execution-receipts
     only while startup pruned all three. Pin the shared list so neither
     loop can silently drop a store again. turn-records joined 2026-07-31. *)
  Alcotest.(check (list string))
    "keeper-scoped stores = metrics + crash-events + execution-receipts + turn-records"
    [ "crash-events"; "execution-receipts"; "metrics"; "turn-records" ]
    (List.sort String.compare SM.keeper_scoped_dated_stores)

let test_top_level_store_list_is_ssot () =
  (* Drift guard for the top-level list: the startup and periodic passes
     kept separate inline sums that drifted (startup lacked
     tool_calls/transition-audit). Pin the shared list. *)
  Alcotest.(check (list string))
    "top-level dated stores pinned"
    (* Compared against List.sort String.compare, so this literal is sorted.
       agent-core-events sits second because a < u; its previous name sorted
       after messages until #27945. *)
    [ "activity-events"
    ; "agent-core-events"
    ; "audit"
    ; "audit-approvals"
    ; "costs"
    ; "events"
    ; "telemetry"
    ; "tool_calls"
    ; "tool_usage"
    ; "transition-audit"
    ; "voice_sessions"
    ]
    (List.sort String.compare SM.top_level_dated_stores)

let test_keeper_scoped_flat_store_list_is_ssot () =
  Alcotest.(check (list string))
    "keeper-scoped flat stores = raw-traces + runtime-manifests"
    [ "raw-traces"; "runtime-manifests" ]
    (List.sort String.compare SM.keeper_scoped_flat_stores)

let test_prune_flat_jsonl_rotation_siblings () =
  (* runtime-manifests rotate whole files to <trace>.jsonl.1 — a plain
     .jsonl suffix check would keep rotation siblings forever. Non-numeric
     trailing extensions must never be removed. *)
  let root = fresh_dir "masc_prune_flat_rot" in
  let write path =
    let oc = open_out path in
    output_string oc "{}\n";
    close_out oc
  in
  let old_ts = Unix.gettimeofday () -. (40. *. 86400.) in
  let old_rotated = Filename.concat root "trace-x.jsonl.1" in
  let old_plain = Filename.concat root "trace-y.jsonl" in
  let old_non_numeric = Filename.concat root "trace-z.jsonl.bak" in
  let fresh_rotated = Filename.concat root "trace-w.jsonl.2" in
  write old_rotated;
  write old_plain;
  write old_non_numeric;
  write fresh_rotated;
  Unix.utimes old_rotated old_ts old_ts;
  Unix.utimes old_plain old_ts old_ts;
  Unix.utimes old_non_numeric old_ts old_ts;
  let n = SM.prune_flat_jsonl_older_than ~days:30 root in
  Alcotest.(check int) "old .jsonl and .jsonl.1 pruned" 2 n;
  Alcotest.(check bool) "old rotation sibling removed" false (Sys.file_exists old_rotated);
  Alcotest.(check bool) "old plain jsonl removed" false (Sys.file_exists old_plain);
  Alcotest.(check bool)
    "non-numeric extension kept" true (Sys.file_exists old_non_numeric);
  Alcotest.(check bool) "fresh rotation sibling kept" true (Sys.file_exists fresh_rotated)

let test_prune_shared_jsonl_stores_production_geometry () =
  (* Round-trip on the production masc-root geometry (guard against
     dual-path derivation no-ops): every covered store gets one stale file
     and, where meaningful, one fresh sibling. prune_dir is the same
     Dated_jsonl-based closure both production passes build. *)
  let masc_root = fresh_dir "masc_shared_prune" in
  let write path =
    Fs_compat.mkdir_p (Filename.dirname path);
    let oc = open_out path in
    output_string oc "{}\n";
    close_out oc
  in
  let old_ts = Unix.gettimeofday () -. (40. *. 86400.) in
  let p segs = List.fold_left Filename.concat masc_root segs in
  (* top-level dated store: stale by filename month, fresh by future month *)
  let agent_core_old = p [ "agent-core-events"; "2020-01"; "01.jsonl" ] in
  let agent_core_fresh = p [ "agent-core-events"; "2999-01"; "01.jsonl" ] in
  (* logs: flat day files, stale by mtime *)
  let logs_old = p [ "logs"; "system_log_2020-01-01.jsonl" ] in
  let logs_fresh = p [ "logs"; "system_log_2999-01-01.jsonl" ] in
  (* keeper-scoped dated store *)
  let turn_old = p [ "keepers"; "keeper-a"; "turn-records"; "2020-01"; "01.jsonl" ] in
  (* keeper-scoped flat stores *)
  let raw_old = p [ "keepers"; "keeper-a"; "raw-traces"; "turn-old.jsonl" ] in
  let manifest_old = p [ "keepers"; "keeper-a"; "runtime-manifests"; "trace-x.jsonl.1" ] in
  let manifest_fresh = p [ "keepers"; "keeper-a"; "runtime-manifests"; "trace-x.jsonl" ] in
  (* Stores that were on no prune list until 2026-08-05. costs and
     audit-approvals are top-level dated; decision_audit is keeper-scoped at
     the masc root, like resilience_audit. *)
  let costs_old = p [ "costs"; "2020-01"; "01.jsonl" ] in
  let costs_fresh = p [ "costs"; "2999-01"; "01.jsonl" ] in
  let approvals_old = p [ "audit-approvals"; "2020-01"; "01.jsonl" ] in
  let decision_old = p [ "decision_audit"; "keeper-a"; "2020-01"; "01.jsonl" ] in
  let decision_fresh = p [ "decision_audit"; "keeper-a"; "2999-01"; "01.jsonl" ] in
  (* messages/: flat .json files, stale by mtime — the dated pruner was a
     no-op on this layout the whole time it sat on the dated list. *)
  let message_old = p [ "messages"; "000000001_taskmaster_wmsg-old_broadcast.json" ] in
  let message_fresh = p [ "messages"; "000000002_taskmaster_wmsg-new_broadcast.json" ] in
  (* tool_usage: dated layout, was on no list (own retention env is opt-in). *)
  let tool_usage_old = p [ "tool_usage"; "2020-01"; "01.jsonl" ] in
  (* reaction-ledger: versioned generation dir between store and months. *)
  let reaction_old = p [ "keepers"; "keeper-a"; "reaction-ledger"; "v7"; "2020-01"; "01.jsonl" ] in
  let reaction_fresh = p [ "keepers"; "keeper-a"; "reaction-ledger"; "v7"; "2999-01"; "01.jsonl" ] in
  List.iter
    write
    [ agent_core_old
    ; agent_core_fresh
    ; logs_old
    ; logs_fresh
    ; turn_old
    ; raw_old
    ; manifest_old
    ; manifest_fresh
    ; costs_old
    ; costs_fresh
    ; approvals_old
    ; decision_old
    ; decision_fresh
    ; message_old
    ; message_fresh
    ; tool_usage_old
    ; reaction_old
    ; reaction_fresh
    ];
  List.iter
    (fun f -> Unix.utimes f old_ts old_ts)
    [ logs_old; raw_old; manifest_old; message_old ];
  let prune_dir dir =
    if Sys.file_exists dir
    then Dated_jsonl.prune (Dated_jsonl.create ~base_dir:dir ()) ~days:30
    else 0
  in
  let n = SM.prune_shared_jsonl_stores ~prune_dir ~days:30 ~masc_root in
  Alcotest.(check int) "eleven stale files pruned" 11 n;
  Alcotest.(check bool) "stale message removed" false (Sys.file_exists message_old);
  Alcotest.(check bool) "fresh message kept" true (Sys.file_exists message_fresh);
  Alcotest.(check bool) "stale tool_usage day removed" false (Sys.file_exists tool_usage_old);
  Alcotest.(check bool)
    "stale reaction-ledger day removed" false (Sys.file_exists reaction_old);
  Alcotest.(check bool)
    "fresh reaction-ledger day kept" true (Sys.file_exists reaction_fresh);
  Alcotest.(check bool) "stale costs day removed" false (Sys.file_exists costs_old);
  Alcotest.(check bool) "future costs day kept" true (Sys.file_exists costs_fresh);
  Alcotest.(check bool)
    "stale audit-approvals day removed" false (Sys.file_exists approvals_old);
  Alcotest.(check bool)
    "stale decision_audit day removed" false (Sys.file_exists decision_old);
  Alcotest.(check bool)
    "future decision_audit day kept" true (Sys.file_exists decision_fresh);
  Alcotest.(check bool) "stale agent-core-events day removed" false (Sys.file_exists agent_core_old);
  Alcotest.(check bool) "future agent-core-events day kept" true (Sys.file_exists agent_core_fresh);
  Alcotest.(check bool) "stale log day removed" false (Sys.file_exists logs_old);
  Alcotest.(check bool) "fresh log day kept" true (Sys.file_exists logs_fresh);
  Alcotest.(check bool) "stale turn-records day removed" false (Sys.file_exists turn_old);
  Alcotest.(check bool) "stale raw-trace removed" false (Sys.file_exists raw_old);
  Alcotest.(check bool)
    "stale manifest rotation removed" false (Sys.file_exists manifest_old);
  Alcotest.(check bool) "fresh manifest kept" true (Sys.file_exists manifest_fresh)

let test_prune_keeper_scoped_stores_visits_all_stores () =
  (* Regression for the 24h loop drift: both loops call this function, so
     every keeper must see prune_dir invoked for all three stores. *)
  visited := [];
  let masc_root = fresh_dir "masc_keeper_scoped" in
  let keepers = Filename.concat masc_root "keepers" in
  List.iter
    (fun name -> Fs_compat.mkdir_p (Filename.concat keepers name))
    [ "keeper-a"; "keeper-b" ];
  let stray = Filename.concat keepers "stray.txt" in
  let oc = open_out stray in
  output_string oc "x";
  close_out oc;
  let n = SM.prune_keeper_scoped_stores ~prune_dir:record_visit ~masc_root in
  Alcotest.(check int) "returns summed prune counts" 0 n;
  let expected =
    List.concat_map
      (fun keeper ->
        List.map
          (fun store -> Filename.concat (Filename.concat keepers keeper) store)
          SM.keeper_scoped_dated_stores)
      [ "keeper-a"; "keeper-b" ]
  in
  Alcotest.(check (list string))
    "every dated store pruned for every keeper"
    (List.sort String.compare expected)
    (List.sort String.compare !visited)

let test_prune_keeper_scoped_stores_missing_root () =
  visited := [];
  let n =
    SM.prune_keeper_scoped_stores
      ~prune_dir:record_visit
      ~masc_root:"/nonexistent/masc-keeper-scoped"
  in
  Alcotest.(check int) "missing keepers root counts 0" 0 n;
  Alcotest.(check int) "prune_dir never called" 0 (List.length !visited)

let () =
  Alcotest.run "server_runtime_startup_maintenance"
    [
      ( "prune_children_dirs",
        [
          Alcotest.test_case "missing root counts zero" `Quick
            test_missing_root_counts_zero;
          Alcotest.test_case "subdirs pruned, stray files skipped" `Quick
            test_subdirs_pruned_and_stray_files_skipped;
        ] );
      ( "prune_flat_jsonl_older_than",
        [
          Alcotest.test_case "populated trajectories dir prunes old files" `Quick
            test_prune_flat_jsonl_removes_old_files;
          Alcotest.test_case "numeric rotation siblings prune, others kept" `Quick
            test_prune_flat_jsonl_rotation_siblings;
        ] );
      ( "prune_keeper_scoped_stores",
        [
          Alcotest.test_case "store list is SSOT (4 stores)" `Quick
            test_keeper_scoped_store_list_is_ssot;
          Alcotest.test_case "visits every dated store per keeper" `Quick
            test_prune_keeper_scoped_stores_visits_all_stores;
          Alcotest.test_case "missing keepers root counts zero" `Quick
            test_prune_keeper_scoped_stores_missing_root;
        ] );
      ( "prune_shared_jsonl_stores",
        [
          Alcotest.test_case "top-level store list pinned" `Quick
            test_top_level_store_list_is_ssot;
          Alcotest.test_case "keeper-scoped flat store list pinned" `Quick
            test_keeper_scoped_flat_store_list_is_ssot;
          Alcotest.test_case "production geometry round-trip" `Quick
            test_prune_shared_jsonl_stores_production_geometry;
        ] );
    ]
