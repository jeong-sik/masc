(** Unit tests for [Server_runtime_startup_maintenance] prune folds. *)

module SM = Server_runtime_startup_maintenance

let fresh_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Unix.realpath dir

let test_prune_refuses_linked_runtime_root () =
  let base = fresh_dir "masc_prune_root" in
  let outside = fresh_dir "masc_prune_outside" in
  Unix.symlink outside (Filename.concat base Common.masc_dirname);
  match SM.prune_shared_jsonl_stores ~days:30
      ~masc_root:(Filename.concat base Common.masc_dirname) with
  | _ -> Alcotest.fail "runtime root was resolved through its link"
  | exception Unix.Unix_error ((Unix.ENOTDIR | Unix.ELOOP), _, _) -> ()

let test_shared_prune_skips_ancestor_links () =
  List.iter (fun (before, after) ->
    let base = fresh_dir "masc_prune_containment" in
    let root = Common.masc_dir_from_base_path ~base_path:base in
    let outside = fresh_dir "masc_prune_foreign" in
    let path root segments = List.fold_left Filename.concat root segments in
    Fs_compat.mkdir_p (Filename.dirname (path root before));
    let target = path outside after in
    Fs_compat.mkdir_p (Filename.dirname target);
    Out_channel.with_open_text target (fun oc -> output_string oc "foreign sentinel");
    Unix.utimes target 1. 1.;
    Unix.symlink outside (path root before);
    Alcotest.(check int) "no foreign file counted" 0
      (SM.prune_shared_jsonl_stores ~days:30 ~masc_root:root);
    Alcotest.(check string) "foreign contents preserved" "foreign sentinel"
      (In_channel.with_open_text target In_channel.input_all))
    [ ["logs"], ["old.jsonl"];
      ["trajectories";"keeper-a"], ["old.jsonl"];
      ["keepers";"keeper-a"], ["turn-records";"2020-01";"01.jsonl"];
      ["keepers";"keeper-a";"raw-traces"], ["old.jsonl"];
      ["keepers";"keeper-a";"reaction-ledger";"v7"], ["2020-01";"01.jsonl"];
      ["decision_audit";"keeper-a"], ["2020-01";"01.jsonl"];
      ["agent-core-events";"2020-01"], ["01.jsonl"];
      ["schedules"], ["signals";"2020-01";"01.jsonl"] ]

let test_shared_prune_accepts_base_alias () =
  let base = fresh_dir "masc_prune_alias_base" in
  let holder = fresh_dir "masc_prune_alias_holder" in
  let alias = Filename.concat holder "workspace" in
  Unix.symlink base alias;
  let old = Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "logs/old.jsonl" in
  Fs_compat.mkdir_p (Filename.dirname old);
  Out_channel.with_open_text old (fun oc -> output_string oc "{}\n");
  Unix.utimes old 1. 1.;
  Alcotest.(check int) "configured BasePath alias still prunes its physical root" 1
    (SM.prune_shared_jsonl_stores ~days:30
      ~masc_root:(Common.masc_dir_from_base_path ~base_path:alias));
  Alcotest.(check bool) "owned old file removed" false (Sys.file_exists old)

(* The flat pass reads and unlinks on a system thread, so another fiber runs
   while it is in flight (#42935). *)
let test_flat_prune_leaves_the_fiber_free () =
  Eio_main.run @@ fun _env ->
  let dir = fresh_dir "masc_prune_flat_off_fiber" in
  let old_file = Filename.concat dir "trace-old.jsonl" in
  Out_channel.with_open_text old_file (fun oc -> output_string oc "{}\n");
  let old_ts = Unix.gettimeofday () -. (40. *. 86400.) in
  Unix.utimes old_file old_ts old_ts;
  let finished = ref false in
  let ran_during_prune = ref false in
  Eio.Fiber.both
    (fun () ->
       ignore (SM.prune_flat_jsonl_older_than ~days:30 dir : int);
       finished := true)
    (fun () -> ran_during_prune := not !finished);
  Alcotest.(check bool) "another fiber ran during the prune" true !ran_during_prune;
  Alcotest.(check bool) "old file removed" false (Sys.file_exists old_file)

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
    SM.prune_flat_jsonl_older_than ~days:30 keeper
  in
  Alcotest.(check int) "old trajectory pruned" 1 n;
  Alcotest.(check bool) "old file removed" false (Sys.file_exists old_file);
  Alcotest.(check bool) "recent file kept" true (Sys.file_exists recent_file);
  Alcotest.(check bool) "non-jsonl file kept" true (Sys.file_exists stray)

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
  let base_path = fresh_dir "masc_shared_prune" in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
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
  let provider_input_old =
    p [ "keepers"; "keeper-a"; "provider-inputs"; "2020-01"; "01.jsonl" ]
  in
  (* keeper-scoped flat stores *)
  let raw_old = p [ "keepers"; "keeper-a"; "raw-traces"; "turn-old.jsonl" ] in
  let manifest_old = p [ "keepers"; "keeper-a"; "runtime-manifests"; "trace-x.jsonl.1" ] in
  let manifest_fresh = p [ "keepers"; "keeper-a"; "runtime-manifests"; "trace-x.jsonl" ] in
  (* costs and audit-approvals are dated stores at the root; decision_audit
     keeps one folder per keeper at the masc root. *)
  let costs_old = p [ "costs"; "2020-01"; "01.jsonl" ] in
  let costs_fresh = p [ "costs"; "2999-01"; "01.jsonl" ] in
  let approvals_old = p [ "audit-approvals"; "2020-01"; "01.jsonl" ] in
  let decision_old = p [ "decision_audit"; "keeper-a"; "2020-01"; "01.jsonl" ] in
  let decision_fresh = p [ "decision_audit"; "keeper-a"; "2999-01"; "01.jsonl" ] in
  (* messages/: flat .json files, stale by mtime — the dated pruner was a
     no-op on this layout the whole time it sat on the dated list. *)
  let message_old = p [ "messages"; "000000001_bravo_wmsg-old_broadcast.json" ] in
  let message_fresh = p [ "messages"; "000000002_bravo_wmsg-new_broadcast.json" ] in
  (* tool_usage: dated layout, was on no list (own retention env is opt-in). *)
  let tool_usage_old = p [ "tool_usage"; "2020-01"; "01.jsonl" ] in
  (* Pruned on append by their own handle until the pass took them over:
     provider usage history at 16 days, wire capture at its own setting
     (3 days by default). *)
  let provider_usage_old = p [ "provider_usage_history"; "2020-01"; "01.jsonl" ] in
  let wire_capture_old = p [ "wire-capture"; "2020-01"; "01.jsonl" ] in
  (* Written under <base>/.masc and on no prune list until the store list
     gave them rules: tool events and continuity requests follow the
     window, verdicts are kept. *)
  let tool_events_old = p [ "tool-events"; "2020-01"; "01.jsonl" ] in
  let verdicts_old = p [ "verdicts"; "2020-01"; "01.jsonl" ] in
  let continuity_old =
    p [ "keepers"; "keeper-a"; "continuity-requests"; "2020-01"; "01.jsonl" ]
  in
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
    ; provider_input_old
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
    ; provider_usage_old
    ; wire_capture_old
    ; tool_events_old
    ; verdicts_old
    ; continuity_old
    ];
  List.iter
    (fun f -> Unix.utimes f old_ts old_ts)
    [ logs_old; raw_old; manifest_old; message_old ];
  let n = SM.prune_shared_jsonl_stores ~days:30 ~masc_root in
  Alcotest.(check int) "sixteen stale files pruned" 16 n;
  Alcotest.(check bool)
    "stale provider usage day removed" false (Sys.file_exists provider_usage_old);
  Alcotest.(check bool)
    "stale wire capture day removed" false (Sys.file_exists wire_capture_old);
  Alcotest.(check bool)
    "stale tool-events day removed" false (Sys.file_exists tool_events_old);
  Alcotest.(check bool) "kept verdicts day stays" true (Sys.file_exists verdicts_old);
  Alcotest.(check bool)
    "stale continuity-requests day removed" false (Sys.file_exists continuity_old);
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
  Alcotest.(check bool)
    "stale provider-inputs day removed"
    false
    (Sys.file_exists provider_input_old);
  Alcotest.(check bool) "stale raw-trace removed" false (Sys.file_exists raw_old);
  Alcotest.(check bool)
    "stale manifest rotation removed" false (Sys.file_exists manifest_old);
  Alcotest.(check bool) "fresh manifest kept" true (Sys.file_exists manifest_fresh)

(* An excluded keeper is named; the names a base path declares are the .toml
   basenames of its keepers directory, and every other file there (memory
   stores share the directory) declares nobody. *)
let test_unknown_typesafeai_exclusions_come_from_declarations () =
  let root = fresh_dir "masc_typesafeai_exclusions" in
  List.iter
    (fun name ->
       Out_channel.with_open_text (Filename.concat root name) (fun oc -> output_string oc ""))
    [ "alpha.toml"; "beta.toml"; "alpha.memory-current.json" ];
  let inherited = Runtime_typesafeai_policy.current () in
  Runtime_typesafeai_policy.publish
    { Runtime_schema.default_typesafeai with excluded_keepers = [ "alpha"; "gamma" ] };
  Fun.protect
    ~finally:(fun () -> Runtime_typesafeai_policy.publish inherited)
    (fun () ->
       Alcotest.(check (list string)) "declared names are the toml basenames"
         [ "alpha"; "beta" ]
         (SM.declared_keeper_names ~keepers_dir:root
          |> Result.get_ok
          |> List.sort compare);
       Alcotest.(check (list string)) "gamma is no keeper" [ "gamma" ]
         (SM.unknown_typesafeai_exclusions ~keepers_dir:root |> Result.get_ok));
  let missing = Filename.concat root "missing" in
  Alcotest.(check bool) "a missing directory is a read failure" true
    (Result.is_error (SM.declared_keeper_names ~keepers_dir:missing));
  Alcotest.(check bool)
    "an unreadable directory cannot accuse every excluded keeper"
    true
    (Result.is_error (SM.unknown_typesafeai_exclusions ~keepers_dir:missing))

(* Recall limited to listed keepers is limited by name, so a misspelt name
   reaches nobody. The names are checked against the same declarations. *)
let test_unknown_memory_recall_keepers_come_from_declarations () =
  let root = fresh_dir "masc_memory_recall_keepers" in
  List.iter
    (fun name ->
       Out_channel.with_open_text (Filename.concat root name) (fun oc -> output_string oc ""))
    [ "alpha.toml"; "beta.toml"; "alpha.memory-current.json" ];
  let inherited = Runtime_typesafeai_policy.current () in
  let publish memory_recall =
    Runtime_typesafeai_policy.publish { Runtime_schema.default_typesafeai with memory_recall }
  in
  Fun.protect
    ~finally:(fun () -> Runtime_typesafeai_policy.publish inherited)
    (fun () ->
       publish
         (Runtime_schema.Memory_recall_on
            (Runtime_schema.Listed_keepers ("alpha", [ "gamma"; "alpha.memory-current.json" ])));
       Alcotest.(check (list string)) "gamma and the memory store are no keepers"
         [ "gamma"; "alpha.memory-current.json" ]
         (SM.unknown_memory_recall_keepers ~keepers_dir:root |> Result.get_ok);
       publish (Runtime_schema.Memory_recall_on Runtime_schema.All_keepers);
       Alcotest.(check (list string)) "all keepers name nobody" []
         (SM.unknown_memory_recall_keepers ~keepers_dir:root |> Result.get_ok);
       publish
         (Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers ("alpha", [ "beta" ])));
       Alcotest.(check (list string)) "every listed keeper is declared" []
         (SM.unknown_memory_recall_keepers ~keepers_dir:root |> Result.get_ok);
       let missing = Filename.concat root "missing" in
       Alcotest.(check bool)
         "an unreadable directory cannot accuse every listed keeper"
         true
         (Result.is_error (SM.unknown_memory_recall_keepers ~keepers_dir:missing));
       (* Nothing is listed, so there is nothing to check and the directory is
          not read: a base path without keepers is not told about a key it
          never set. *)
       List.iter
         (fun (label, memory_recall) ->
            publish memory_recall;
            Alcotest.(check (list string)) label []
              (SM.unknown_memory_recall_keepers ~keepers_dir:missing |> Result.get_ok))
         [ "recall is off", Runtime_schema.Memory_recall_off
         ; "recall covers every keeper", Runtime_schema.Memory_recall_on Runtime_schema.All_keepers
         ])

let test_prune_empty_completion_review_and_verifier_executions () =
  let base_path = fresh_dir "masc_completion_review_prune" in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let old_review_file =
    List.fold_left Filename.concat masc_root
      [ "keepers"; "completion-review-dead0001"; "continuity-requests"; "2020-01"; "01.jsonl" ]
  in
  let live_review_file =
    List.fold_left Filename.concat masc_root
      [ "keepers"; "completion-review-live0002"; "continuity-requests"; "2999-01"; "01.jsonl" ]
  in
  Fs_compat.mkdir_p (Filename.dirname old_review_file);
  Fs_compat.mkdir_p (Filename.dirname live_review_file);
  Fs_compat.save_file old_review_file "{}\n";
  Fs_compat.save_file live_review_file "{}\n";
  let pruned = SM.prune_shared_jsonl_stores ~days:30 ~masc_root in
  Alcotest.(check int) "only old review day file counted" 1 pruned;
  Alcotest.(check bool) "empty old completion-review dir removed" false
    (Sys.file_exists (List.fold_left Filename.concat masc_root [ "keepers"; "completion-review-dead0001" ]));
  Alcotest.(check bool) "active completion-review dir preserved" true
    (Sys.file_exists live_review_file);
  (* Verifier executions: keep live-referenced and recent settled, remove aged settled. *)
  let store =
    Masc.Lane_addon_store.create ~root:(Masc.Lane_addon_store.directory ~masc_dir:masc_root)
  in
  let live_req = `Assoc [ "input", `String "active-review" ] in
  (match
     Masc.Lane_addon_tool_request_owner.retain
       ~store
       ~scope:Masc.Verifier_review_owner.scope
       ~request_id:"verif-live:attempt-0"
       ~installation_id:"inst-1"
       ~package_id:"pkg-1"
       ~tool:"verifier_review"
       ~summary:`Null
       ~request:live_req
   with
   | Ok _ -> ()
   | Error err -> Alcotest.fail (Masc.Lane_addon_tool_request_owner.error_to_string err));
  let live_digest =
    match Masc.Lane_addon_tool_request_owner.request_digest live_req with
    | Ok d -> d
    | Error d -> Alcotest.fail d
  in
  let settled_old_digest = String.make 64 'b' in
  let settled_fresh_digest = String.make 64 'c' in
  let exec_root = Filename.concat masc_root "verifier-executions" in
  let now = 1_800_000_000.0 in
  let old_ts = now -. (40.0 *. Masc_time_constants.day) in
  let fresh_ts = now -. 60.0 in
  let mk_exec digest ts =
    let dir = Filename.concat exec_root digest in
    let file = Filename.concat dir "journal.json" in
    Fs_compat.mkdir_p dir;
    Fs_compat.save_file file "{}";
    Unix.utimes file ts ts;
    Unix.utimes dir ts ts;
    dir
  in
  let live_dir = mk_exec live_digest old_ts in
  let old_dir = mk_exec settled_old_digest old_ts in
  let fresh_dir_exec = mk_exec settled_fresh_digest fresh_ts in
  let removed =
    match SM.prune_settled_verifier_executions ~now ~base_path ~days:30 () with
    | Ok n -> n
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check int) "only aged settled verifier execution removed" 1 removed;
  Alcotest.(check bool) "aged settled execution removed" false (Sys.file_exists old_dir);
  Alcotest.(check bool) "live referenced execution kept even if old" true (Sys.file_exists live_dir);
  Alcotest.(check bool) "fresh settled execution kept" true (Sys.file_exists fresh_dir_exec)

let test_prune_terminal_shutdown_operations_and_empty_dirs () =
  Eio_main.run @@ fun _env ->
  let base_path = fresh_dir "masc_shutdown_ops_prune" in
  let config = Masc.Workspace.default_config base_path in
  let ops_root =
    Filename.concat
      (Masc.Workspace.keepers_runtime_dir config)
      (Common.keeper_runtime_store_dirname Common.Keeper_shutdown_operations)
  in
  let empty_legacy_dir = Filename.concat ops_root "_legacy-empty" in
  Fs_compat.mkdir_p empty_legacy_dir;
  let now = 1_800_000_000.0 in
  let old_ts = now -. (40.0 *. Masc_time_constants.day) in
  let trace_id =
    match Keeper_id.Trace_id.of_string "trace-shutdown-prune-test" with
    | Ok id -> id
    | Error detail -> Alcotest.fail detail
  in
  let digest =
    match Masc.Keeper_meta_json.Snapshot_digest.of_string (String.make 64 'd') with
    | Ok d -> d
    | Error detail -> Alcotest.fail detail
  in
  let cleanup_evidence =
    { Masc.Keeper_shutdown_types.settled_task_ids = []
    ; pending_confirms_removed = 0
    ; meta_snapshot_digest = digest
    }
  in
  let mk_op ~keeper_name ~reason ~phase =
    let op_id = Masc.Keeper_shutdown_types.Operation_id.generate () in
    let op : Masc.Keeper_shutdown_types.t =
      { schema_version = Masc.Keeper_shutdown_types.schema_version
      ; revision = 1
      ; operation_id = op_id
      ; keeper_name
      ; lane_ownership = Dormant_meta
      ; trace_id
      ; actor = "test"
      ; cleanup_intent = { reason; remove_session = false }
      ; turn_disposition = No_inflight_turn
      ; expected_backlog_version = 1
      ; owned_task_ids = []
      ; join_evidence = None
      ; phase
      ; created_at = "2026-01-01T00:00:00Z"
      ; updated_at = "2026-01-01T00:00:00Z"
      }
    in
    (match Masc.Keeper_shutdown_store.persist_new ~config op with
     | Ok () -> ()
     | Error err -> Alcotest.fail (Masc.Keeper_shutdown_store.error_to_string err));
    match Masc.Keeper_shutdown_store.path ~config ~keeper_name op_id with
    | Ok p ->
      Unix.utimes p old_ts old_ts;
      p
    | Error err -> Alcotest.fail (Masc.Keeper_shutdown_store.error_to_string err)
  in
  let settled_path =
    mk_op
      ~keeper_name:"settled-keeper"
      ~reason:Masc.Keeper_shutdown_types.Operator_stop_retain_meta
      ~phase:
        (Masc.Keeper_shutdown_types.Finalized
           { cleanup = cleanup_evidence
           ; meta_removed = false
           ; session_removed = false
           ; registry_unregistered = true
           ; completion = Masc.Keeper_shutdown_types.Completion_not_requested
           })
  in
  let blocked_path =
    mk_op
      ~keeper_name:"blocked-keeper"
      ~reason:Masc.Keeper_shutdown_types.Operator_stop_retain_meta
      ~phase:(Masc.Keeper_shutdown_types.Blocked { stage = Task_settlement; detail = "pending" })
  in
  let purge_path =
    mk_op
      ~keeper_name:"purged-keeper"
      ~reason:(Masc.Keeper_shutdown_types.Dashboard_keeper_purge { requested_name = "purged-keeper" })
      ~phase:
        (Masc.Keeper_shutdown_types.Finalized
           { cleanup = cleanup_evidence
           ; meta_removed = true
           ; session_removed = false
           ; registry_unregistered = true
           ; completion = Masc.Keeper_shutdown_types.Completion_delivered Dashboard_keeper_purged
           })
  in
  let corrupt_dir = Filename.concat ops_root "_corrupt-keeper" in
  Fs_compat.mkdir_p corrupt_dir;
  let corrupt_id = Masc.Keeper_shutdown_types.Operation_id.generate () in
  let corrupt_path =
    Filename.concat corrupt_dir (Masc.Keeper_shutdown_types.Operation_id.to_string corrupt_id ^ ".json")
  in
  Fs_compat.save_file corrupt_path "{not valid json";
  Unix.utimes corrupt_path old_ts old_ts;
  let report =
    match
      Masc.Keeper_shutdown_store.prune_terminal_and_empty_dirs
        ~now
        ~config
        ~older_than_seconds:(30.0 *. Masc_time_constants.day)
        ()
    with
    | Ok r -> r
    | Error err -> Alcotest.fail (Masc.Keeper_shutdown_store.error_to_string err)
  in
  Alcotest.(check int) "one aged terminal operation pruned" 1 report.pruned_operations;
  Alcotest.(check int) "two empty owner dirs pruned (settled + legacy empty)" 2 report.pruned_empty_dirs;
  Alcotest.(check bool) "legacy empty dir removed" false (Sys.file_exists empty_legacy_dir);
  Alcotest.(check bool) "settled op removed" false (Sys.file_exists settled_path);
  Alcotest.(check bool) "settled keeper dir removed" false (Sys.file_exists (Filename.dirname settled_path));
  Alcotest.(check bool) "blocked op preserved" true (Sys.file_exists blocked_path);
  Alcotest.(check bool) "dashboard purge receipt preserved" true (Sys.file_exists purge_path);
  Alcotest.(check bool) "corrupt record preserved" true (Sys.file_exists corrupt_path)

let test_sweep_atomic_orphans_removes_dead_stage_and_preserves_flocked () =
  let base_path = fresh_dir "masc_atomic_orphan_sweep" in
  let ext_config_dir = fresh_dir "masc_ext_config_dir" in
  let ext_keepers = Filename.concat ext_config_dir "keepers" in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  Fs_compat.mkdir_p masc_root;
  Fs_compat.mkdir_p ext_keepers;
  let dead_stage = Filename.concat masc_root ".private_jsonl_dead_0001.stage" in
  let live_stage = Filename.concat masc_root ".private_jsonl_live_0002.stage" in
  let nonempty_atomic = Filename.concat masc_root ".atomic_99999_0.tmp" in
  let ext_nonempty_atomic = Filename.concat ext_keepers ".atomic_ext_88.tmp" in
  Fs_compat.save_file dead_stage "partial dead write\n";
  Fs_compat.save_file live_stage "active writer stage\n";
  Fs_compat.save_file nonempty_atomic "uncommitted payload";
  Fs_compat.save_file ext_nonempty_atomic "external uncommitted payload";
  (* Live in-flight open_atomic_temp_file writer must NEVER be deleted or moved. *)
  let live_atomic_path, live_atomic_ch =
    Fs_compat.open_atomic_temp_file ~temp_dir:masc_root ()
  in
  let live_fd = Unix.openfile live_stage [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  let prev_cfg_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" ext_config_dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev_cfg_dir with
       | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      close_out_noerr live_atomic_ch;
      (try Unix.unlink live_atomic_path with Unix.Unix_error _ -> ());
      Unix.close live_fd)
    (fun () ->
       output_string live_atomic_ch "in-flight atomic write";
       flush live_atomic_ch;
       Alcotest.(check bool) "acquire stage flock on live stage" true
         (Fs_compat.try_lock_stage_fd_for_testing live_fd);
       let report = SM.sweep_atomic_orphans ~base_path in
       Alcotest.(check int) "zero failures" 0 (List.length report.failures);
       Alcotest.(check int) "dead stage unlinked" 1 report.deleted;
       Alcotest.(check int) "2 dead nonempty atomics preserved (masc_root + external config_keepers)" 2 report.preserved;
       Alcotest.(check bool) "dead stage gone" false (Sys.file_exists dead_stage);
       Alcotest.(check bool) "live flocked stage untouched" true (Sys.file_exists live_stage);
       Alcotest.(check bool) "live in-flight atomic temp file untouched" true (Sys.file_exists live_atomic_path);
       Alcotest.(check bool) "no unclassified .masc/.recovered created" false
         (Sys.file_exists (Filename.concat masc_root ".recovered"));
       Alcotest.(check bool) "no unclassified <external config_keepers>/.recovered created" false
         (Sys.file_exists (Filename.concat ext_keepers ".recovered"));
       Alcotest.(check bool) "in-workspace orphan preserved inside classified fs-publication-recovery" true
         (Sys.file_exists
            (List.fold_left Filename.concat masc_root
               [ Fs_compat.Publication_recovery.directory_leaf; ".recovered"; "root"; ".atomic_99999_0.tmp" ]));
       Alcotest.(check bool) "external config_keepers orphan routed into classified fs-publication-recovery" true
         (Sys.file_exists
            (List.fold_left Filename.concat masc_root
               [ Fs_compat.Publication_recovery.directory_leaf; ".recovered"; "root"; ".atomic_ext_88.tmp" ]));
       match Tool_blob_maintenance.unclassified_entries ~base_path Server_tool_blob_scope.scope with
       | Ok entries ->
         Alcotest.(check (list string)) "blob scope has zero unclassified entries" []
           (List.map Tool_blob_maintenance.unclassified_entry_to_string entries)
       | Error err -> Alcotest.fail (Tool_blob_maintenance.error_to_string err))

let test_sweep_stale_durable_locks_respects_held_and_targets () =
  let base_path = fresh_dir "masc_stale_locks" in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let keepers_cfg = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p masc_root;
  Fs_compat.mkdir_p keepers_cfg;
  (* 1. Antigravity prepare locks (File_lock_eio-owned) *)
  let dead_agy_lock =
    Runtime_antigravity_home.keeper_prepare_lock_path ~runtime_root:masc_root ~owner_leaf:"deadleaf"
  in
  let live_agy_lock =
    Runtime_antigravity_home.keeper_prepare_lock_path ~runtime_root:masc_root ~owner_leaf:"liveleaf"
  in
  let live_agy_home =
    Runtime_antigravity_home.keeper_home_dir ~runtime_root:masc_root ~owner_leaf:"liveleaf"
  in
  Fs_compat.save_file dead_agy_lock "";
  Fs_compat.save_file live_agy_lock "";
  Fs_compat.mkdir_p live_agy_home;
  (* 2. Artifact draft locks (Fs_compat private JSONL stable locks) *)
  let drafts_dir = Filename.concat masc_root Masc.Artifact_draft_store.dirname in
  Fs_compat.mkdir_p drafts_dir;
  let dead_draft_lock = Filename.concat drafts_dir "gone.json.lock" in
  let held_draft_data = Filename.concat drafts_dir "held.json" in
  let held_draft_lock = Filename.concat drafts_dir "held.json.lock" in
  Fs_compat.save_file dead_draft_lock "1";
  let missing_draft_snapshot =
    match Fs_compat.read_private_jsonl_durable_locked_result held_draft_data ~after:None with
    | Ok snap -> snap
    | Error err -> Alcotest.fail (Fs_compat.private_jsonl_transaction_error_to_string err)
  in
  (* 3. Trace checkpoint locks (File_lock_eio-owned): one dead, one held *)
  let traces_dir = Filename.concat masc_root Workspace_init.traces_dirname in
  Fs_compat.mkdir_p traces_dir;
  let dead_trace_lock = Filename.concat traces_dir "dead-session.checkpoint.lock" in
  let held_trace_lock = Filename.concat traces_dir "live-session.checkpoint.lock" in
  Fs_compat.save_file dead_trace_lock "";
  Fs_compat.save_file held_trace_lock "";
  (* 4. Board attention candidate locks (Fs_compat private JSONL stable locks):
        declared keeper with TOML filename != internal name & sanitized segment,
        plus one retired keeper. *)
  let bac_dir = Filename.concat masc_root Masc.Keeper_board_attention_candidate.dirname in
  Fs_compat.mkdir_p bac_dir;
  Fs_compat.save_file (Filename.concat keepers_cfg "alias.toml") "[keeper]\nname=\"Team.Alpha\"\n";
  let sanitized_alpha = Workspace_utils_backend_setup.sanitize_namespace_segment "Team.Alpha" in
  let declared_bac_lock = Filename.concat bac_dir (sanitized_alpha ^ ".jsonl.lock") in
  let retired_bac_lock = Filename.concat bac_dir "retired.jsonl.lock" in
  Fs_compat.save_file declared_bac_lock "1";
  Fs_compat.save_file retired_bac_lock "1";
  (* Hold BOTH a real same-process Fs_compat private JSONL snapshot guard on
     held_draft_data (target still absent!) AND a File_lock_eio durable lock on
     held_trace_lock during the sweep. Verify neither is removed AND the
     same-process POSIX lockf on held_draft_lock is NEVER dropped! *)
  let child_saw_draft_locked = ref false in
  let report =
    match
      Fs_compat.with_private_jsonl_snapshot_guard_result
        held_draft_data
        ~expected:missing_draft_snapshot
        ~f:(fun () ->
          let r =
            match
              File_lock_eio.with_durable_lock ~lock_path:held_trace_lock (fun () ->
                SM.sweep_stale_durable_locks ~base_path)
            with
            | Ok r -> r
            | Error err -> Alcotest.fail (File_lock_eio.durable_lock_error_to_string err)
          in
          (* Prove our POSIX lockf on held_draft_lock survived the sweep intact! *)
          let pid =
            Unix.create_process
              "python3"
              [| "python3"
               ; "-c"
               ; "import fcntl, os, sys; fd = os.open(sys.argv[1], os.O_WRONLY); fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)"
               ; held_draft_lock
              |]
              Unix.stdin
              Unix.stdout
              Unix.stderr
          in
          let rec wait () =
            match Unix.waitpid [] pid with
            | _, status -> status
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
          in
          (match wait () with
           | Unix.WEXITED 0 -> child_saw_draft_locked := false
           | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
             child_saw_draft_locked := true);
          r)
    with
    | Fs_compat.Guard_executed { value; cleanup_failures = [] } -> value
    | Fs_compat.Guard_executed { cleanup_failures = _ :: _; _ } ->
      Alcotest.fail "private JSONL guard reported cleanup failures"
    | Fs_compat.Guard_refused _ ->
      Alcotest.fail "private JSONL guard refused entry on fresh missing snapshot"
  in
  Alcotest.(check bool) "same-process private JSONL POSIX lockf remained intact" true !child_saw_draft_locked;
  Alcotest.(check int) "4 unheld target-absent locks removed" 4 report.removed;
  Alcotest.(check int) "2 held locks kept (draft + trace)" 2 report.kept_held;
  Alcotest.(check int) "2 target/declared locks kept" 2 report.kept_target_present;
  Alcotest.(check int) "0 lock cleanup failures" 0 report.failed;
  Alcotest.(check bool) "dead antigravity lock removed" false (Sys.file_exists dead_agy_lock);
  Alcotest.(check bool) "live antigravity lock kept" true (Sys.file_exists live_agy_lock);
  Alcotest.(check bool) "dead draft lock removed" false (Sys.file_exists dead_draft_lock);
  Alcotest.(check bool) "held draft lock kept" true (Sys.file_exists held_draft_lock);
  Alcotest.(check bool) "dead trace lock removed" false (Sys.file_exists dead_trace_lock);
  Alcotest.(check bool) "held trace lock kept" true (Sys.file_exists held_trace_lock);
  Alcotest.(check bool) "sanitized declared keeper attention lock kept" true (Sys.file_exists declared_bac_lock);
  Alcotest.(check bool) "retired keeper attention lock removed" false (Sys.file_exists retired_bac_lock);
  (* Corrupt keeper TOML fails closed: preserves unknown board attention locks
     even while now-released draft/trace locks are cleaned up. *)
  Fs_compat.save_file (Filename.concat keepers_cfg "corrupt.toml") "[[[ invalid";
  let uncertain_bac_lock = Filename.concat bac_dir "uncertain.jsonl.lock" in
  Fs_compat.save_file uncertain_bac_lock "1";
  let corrupt_report = SM.sweep_stale_durable_locks ~base_path in
  Alcotest.(check int) "only the 2 now-released non-board locks removed" 2 corrupt_report.removed;
  Alcotest.(check bool) "board lock preserved fail-closed when roster corrupt" true
    (Sys.file_exists uncertain_bac_lock)

let test_sweep_stale_temp_orphans_pid_and_age_safety () =
  let temp_dir = fresh_dir "masc_temp_sweep" in
  let outside = fresh_dir "masc_temp_outside" in
  let outside_sentinel = Filename.concat outside "keep.txt" in
  Fs_compat.save_file outside_sentinel "precious";
  let now = 1_800_000_000.0 in
  let old_ts = now -. (48.0 *. 3600.0) in
  let fresh_ts = now -. 600.0 in
  let dead_review = Filename.concat temp_dir "masc-completion-review-999991-dead" in
  let live_review = Filename.concat temp_dir "masc-completion-review-888888-live" in
  let dead_claude = Filename.concat temp_dir "masc-claude-system-999991-dead.txt" in
  let dead_stderr = Filename.concat temp_dir "masc_process_eio_stderr_999991_dead.tmp" in
  let untagged_old_acp = Filename.concat temp_dir "masc-agy-acp-untagged-old" in
  let dead_pid_acp = Filename.concat temp_dir "masc-agy-acp-999991-dead" in
  let live_pid_acp = Filename.concat temp_dir "masc-agy-acp-888888-live" in
  let old_usage = Filename.concat temp_dir "masc-antigravity-usage-old" in
  let fresh_usage = Filename.concat temp_dir "masc-antigravity-usage-fresh" in
  let symlink_usage = Filename.concat temp_dir "masc-antigravity-usage-link" in
  let unrelated = Filename.concat temp_dir "unrelated-file.txt" in
  Fs_compat.mkdir_p dead_review;
  Fs_compat.save_file (Filename.concat dead_review "scratch.txt") "x";
  Fs_compat.mkdir_p live_review;
  Fs_compat.save_file dead_claude "prompt";
  Fs_compat.save_file dead_stderr "err";
  Fs_compat.mkdir_p untagged_old_acp;
  let untagged_acp_child = Filename.concat untagged_old_acp "mcp_config.json" in
  Fs_compat.save_file untagged_acp_child "{}";
  Unix.utimes untagged_acp_child old_ts old_ts;
  Unix.utimes untagged_old_acp old_ts old_ts;
  Fs_compat.mkdir_p dead_pid_acp;
  Fs_compat.save_file (Filename.concat dead_pid_acp "mcp_config.json") "{}";
  Fs_compat.mkdir_p live_pid_acp;
  Fs_compat.save_file (Filename.concat live_pid_acp "mcp_config.json") "{}";
  Fs_compat.mkdir_p old_usage;
  Unix.utimes old_usage old_ts old_ts;
  Fs_compat.mkdir_p fresh_usage;
  Unix.utimes fresh_usage fresh_ts fresh_ts;
  Unix.symlink outside symlink_usage;
  Fs_compat.save_file unrelated "keep";
  Unix.utimes unrelated old_ts old_ts;
  let report =
    SM.sweep_stale_temp_orphans
      ~temp_dir
      ~min_age_seconds:Masc_time_constants.day
      ~is_pid_alive:(fun pid -> pid = 888888)
      ~now
      ()
  in
  Alcotest.(check int) "2 dead-pid temp files removed" 2 report.removed_files;
  Alcotest.(check int) "3 temp dirs removed (dead review + dead-pid acp + aged usage)" 3 report.removed_dirs;
  Alcotest.(check int) "3 live/fresh entries skipped (live review + live acp + fresh usage)" 3 report.skipped_live;
  Alcotest.(check int) "0 failures" 0 report.failed;
  Alcotest.(check bool) "dead review dir removed" false (Sys.file_exists dead_review);
  Alcotest.(check bool) "live review dir kept" true (Sys.file_exists live_review);
  Alcotest.(check bool) "dead claude file removed" false (Sys.file_exists dead_claude);
  Alcotest.(check bool) "dead stderr file removed" false (Sys.file_exists dead_stderr);
  Alcotest.(check bool) "untagged old acp dir preserved (may belong to long-lived persistent ACP child)" true
    (Sys.file_exists untagged_old_acp);
  Alcotest.(check bool) "dead-pid acp dir removed" false (Sys.file_exists dead_pid_acp);
  Alcotest.(check bool) "live-pid acp dir kept" true (Sys.file_exists live_pid_acp);
  Alcotest.(check bool) "aged usage dir removed" false (Sys.file_exists old_usage);
  Alcotest.(check bool) "fresh usage dir kept" true (Sys.file_exists fresh_usage);
  Alcotest.(check bool) "outside symlink target untouched" true (Sys.file_exists outside_sentinel);
  Alcotest.(check bool) "unrelated file untouched" true (Sys.file_exists unrelated)

(* Obtain a guaranteed-dead PID by spawning and reaping a trivial child process. *)
let dead_pid_for_test () =
  let pid =
    Unix.create_process "/bin/sh" [| "/bin/sh"; "-c"; "exit 0" |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  let rec wait () =
    match Unix.waitpid [] pid with
    | _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
  in
  wait ();
  pid

let make_shutdown_op_fixture ~config ~old_ts ~keeper_name ~reason ~phase =
  let trace_id =
    match Keeper_id.Trace_id.of_string "trace-orphan-systhread-test" with
    | Ok id -> id
    | Error detail -> Alcotest.fail detail
  in
  let op_id = Masc.Keeper_shutdown_types.Operation_id.generate () in
  let op : Masc.Keeper_shutdown_types.t =
    { schema_version = Masc.Keeper_shutdown_types.schema_version
    ; revision = 1
    ; operation_id = op_id
    ; keeper_name
    ; lane_ownership = Dormant_meta
    ; trace_id
    ; actor = "test"
    ; cleanup_intent = { reason; remove_session = false }
    ; turn_disposition = No_inflight_turn
    ; expected_backlog_version = 1
    ; owned_task_ids = []
    ; join_evidence = None
    ; phase
    ; created_at = "2026-01-01T00:00:00Z"
    ; updated_at = "2026-01-01T00:00:00Z"
    }
  in
  (match Masc.Keeper_shutdown_store.persist_new ~config op with
   | Ok () -> ()
   | Error err -> Alcotest.fail (Masc.Keeper_shutdown_store.error_to_string err));
  match Masc.Keeper_shutdown_store.path ~config ~keeper_name op_id with
  | Ok p ->
    Unix.utimes p old_ts old_ts;
    op_id, p
  | Error err -> Alcotest.fail (Masc.Keeper_shutdown_store.error_to_string err)

let test_startup_sweep_orphan_hygiene_runs_in_systhread_without_eio_effects () =
  (* Regression for live v0.79.0 production failure:
     [startup_sweep_orphan_hygiene] runs all five sweep phases inside
     [Systhread_host.run] (a non-Eio OS systhread). Previously
     [Keeper_shutdown_store.with_operation_lock] used [Eio.Mutex.use_rw ~protect:true]
     / [use_ro], raising [Stdlib.Effect.Unhandled(Eio__core__Cancel.Get_context)]
     mid-sweep and aborting shutdown-dir, verifier-execution, and temp sweeps. *)
  let base_path = fresh_dir "masc_startup_orphan_hygiene_e2e" in
  let isolated_temp = fresh_dir "masc_startup_orphan_temp" in
  let dead_pid = dead_pid_for_test () in
  let prev_temp_dir = Filename.get_temp_dir_name () in
  let prev_cfg_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  let prev_fs = Fs_compat.get_fs_opt () in
  let prev_guard = Eio_guard.is_ready () in
  Unix.unsetenv "MASC_CONFIG_DIR";
  Filename.set_temp_dir_name isolated_temp;
  Fun.protect
    ~finally:(fun () ->
      Filename.set_temp_dir_name prev_temp_dir;
      (match prev_cfg_dir with
       | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
       | None -> Unix.unsetenv "MASC_CONFIG_DIR");
      (match prev_fs with
       | Some fs -> Fs_compat.set_fs fs
       | None -> Fs_compat.clear_fs ());
      if prev_guard then Eio_guard.enable () else Eio_guard.disable ())
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Eio_guard.enable ();
       Eio.Switch.run @@ fun sw ->
       let state =
         Masc.Mcp_server.create_state_eio
           ~sw
           ~proc_mgr:(Eio.Stdenv.process_mgr env)
           ~fs:(Eio.Stdenv.fs env)
           ~clock:(Eio.Stdenv.clock env)
           ~mono_clock:(Eio.Stdenv.mono_clock env)
           ~net:(Eio.Stdenv.net env)
           ~base_path
       in
       let config = Masc.Mcp_server.workspace_config state in
       let masc_root = Common.masc_dir_from_base_path ~base_path in
       let now = Unix.gettimeofday () in
       let old_ts = now -. (40.0 *. Masc_time_constants.day) in
       (* 1. Atomic staging orphan *)
       let dead_stage = Filename.concat masc_root ".private_jsonl_dead_99.stage" in
       Fs_compat.mkdir_p masc_root;
       Fs_compat.save_file dead_stage "aborted stage\n";
       (* 2. Stale durable locks (.prepare.lock + .checkpoint.lock) *)
       let dead_agy_lock =
         Runtime_antigravity_home.keeper_prepare_lock_path
           ~runtime_root:masc_root ~owner_leaf:"deadleaf"
       in
       let live_agy_lock =
         Runtime_antigravity_home.keeper_prepare_lock_path
           ~runtime_root:masc_root ~owner_leaf:"liveleaf"
       in
       let live_agy_home =
         Runtime_antigravity_home.keeper_home_dir
           ~runtime_root:masc_root ~owner_leaf:"liveleaf"
       in
       Fs_compat.save_file dead_agy_lock "";
       Fs_compat.save_file live_agy_lock "";
       Fs_compat.mkdir_p live_agy_home;
       let traces_dir = Filename.concat masc_root Workspace_init.traces_dirname in
       Fs_compat.mkdir_p traces_dir;
       let dead_trace_lock = Filename.concat traces_dir "dead-session.checkpoint.lock" in
       Fs_compat.save_file dead_trace_lock "";
       (* 3. Shutdown operations: aged terminal + empty legacy dir + preserved blocked op *)
       let ops_root =
         Filename.concat
           (Masc.Workspace.keepers_runtime_dir config)
           (Common.keeper_runtime_store_dirname Common.Keeper_shutdown_operations)
       in
       let empty_legacy_dir = Filename.concat ops_root "_legacy-empty" in
       Fs_compat.mkdir_p empty_legacy_dir;
       let digest =
         match Masc.Keeper_meta_json.Snapshot_digest.of_string (String.make 64 'e') with
         | Ok d -> d
         | Error detail -> Alcotest.fail detail
       in
       let cleanup_evidence =
         { Masc.Keeper_shutdown_types.settled_task_ids = []
         ; pending_confirms_removed = 0
         ; meta_snapshot_digest = digest
         }
       in
       let settled_op_id, settled_path =
         make_shutdown_op_fixture
           ~config
           ~old_ts
           ~keeper_name:"settled-systhread-keeper"
           ~reason:Masc.Keeper_shutdown_types.Operator_stop_retain_meta
           ~phase:
             (Masc.Keeper_shutdown_types.Finalized
                { cleanup = cleanup_evidence
                ; meta_removed = false
                ; session_removed = false
                ; registry_unregistered = true
                ; completion = Masc.Keeper_shutdown_types.Completion_not_requested
                })
       in
       let _blocked_op_id, blocked_path =
         make_shutdown_op_fixture
           ~config
           ~old_ts
           ~keeper_name:"blocked-systhread-keeper"
           ~reason:Masc.Keeper_shutdown_types.Operator_stop_retain_meta
           ~phase:
             (Masc.Keeper_shutdown_types.Blocked
                { stage = Task_settlement; detail = "pending" })
       in
       (* 4. Aged settled verifier execution dir *)
       let exec_root = Filename.concat masc_root "verifier-executions" in
       let old_exec_dir = Filename.concat exec_root (String.make 64 'a') in
       let old_exec_file = Filename.concat old_exec_dir "journal.json" in
       Fs_compat.mkdir_p old_exec_dir;
       Fs_compat.save_file old_exec_file "{}";
       Unix.utimes old_exec_file old_ts old_ts;
       Unix.utimes old_exec_dir old_ts old_ts;
       (* 5. Temp orphans in isolated temp dir *)
       let dead_temp_file =
         Filename.concat
           isolated_temp
           (Printf.sprintf "masc-claude-system-%d-dead.txt" dead_pid)
       in
       let dead_temp_dir =
         Filename.concat
           isolated_temp
           (Printf.sprintf "masc-completion-review-%d-dead" dead_pid)
       in
       let aged_usage_dir = Filename.concat isolated_temp "masc-antigravity-usage-old" in
       Fs_compat.save_file dead_temp_file "prompt";
       Fs_compat.mkdir_p dead_temp_dir;
       Fs_compat.save_file (Filename.concat dead_temp_dir "scratch.txt") "x";
       Fs_compat.mkdir_p aged_usage_dir;
       Unix.utimes aged_usage_dir old_ts old_ts;
       (* Hold the shutdown operation write lock concurrently from an Eio fiber
          while [startup_sweep_orphan_hygiene] runs on a real OS systhread via
          [Systhread_host.run]. This exercises BOTH contended cross-context
          waiting ([Read] and [Write]) and uncontended [Write] in [Non_eio]. *)
       let holder_entered, resolve_holder_entered = Eio.Promise.create () in
       let release_holder, resolve_release_holder = Eio.Promise.create () in
       let sweep_done, resolve_sweep_done = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         (match
            Masc.Keeper_shutdown_store.For_testing.with_operation_write_lock
              ~config
              ~keeper_name:"settled-systhread-keeper"
              settled_op_id
              (fun () ->
                 Eio.Promise.resolve resolve_holder_entered ();
                 Eio.Promise.await release_holder)
          with
          | Ok () -> ()
          | Error err -> Alcotest.fail (Masc.Keeper_shutdown_store.error_to_string err)));
       Eio.Promise.await holder_entered;
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             SM.startup_sweep_orphan_hygiene state;
             Ok ()
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn -> Error (Printexc.to_string exn)
         in
         Eio.Promise.resolve resolve_sweep_done outcome);
       (* Let the systhread reach the contended shutdown lock, then release the fiber lock. *)
       Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
       Eio.Promise.resolve resolve_release_holder ();
       (match Eio.Promise.await sweep_done with
        | Ok () -> ()
        | Error detail ->
          Alcotest.fail ("startup_sweep_orphan_hygiene raised inside systhread: " ^ detail));
       Alcotest.(check bool) "phase 1: dead stage removed" false (Sys.file_exists dead_stage);
       Alcotest.(check bool) "phase 2: dead .prepare.lock removed" false (Sys.file_exists dead_agy_lock);
       Alcotest.(check bool) "phase 2: live .prepare.lock kept" true (Sys.file_exists live_agy_lock);
       Alcotest.(check bool) "phase 2: dead .checkpoint.lock removed" false (Sys.file_exists dead_trace_lock);
       Alcotest.(check bool) "phase 3: aged terminal shutdown op removed" false (Sys.file_exists settled_path);
       Alcotest.(check bool) "phase 3: settled shutdown owner dir removed" false
         (Sys.file_exists (Filename.dirname settled_path));
       Alcotest.(check bool) "phase 3: empty legacy shutdown owner dir removed" false
         (Sys.file_exists empty_legacy_dir);
       Alcotest.(check bool) "phase 3: blocked shutdown op preserved" true (Sys.file_exists blocked_path);
       Alcotest.(check bool) "phase 4: aged settled verifier execution removed" false
         (Sys.file_exists old_exec_dir);
       Alcotest.(check bool) "phase 5: dead-pid temp file removed" false (Sys.file_exists dead_temp_file);
       Alcotest.(check bool) "phase 5: dead-pid temp dir removed" false (Sys.file_exists dead_temp_dir);
       Alcotest.(check bool) "phase 5: aged usage temp dir removed" false (Sys.file_exists aged_usage_dir))

let test_orphan_hygiene_phases_run_in_raw_os_systhread_outside_eio () =
  (* Execute every orphan hygiene sweep phase inside a real OS systhread
     ([Thread.create]) with NO Eio scheduler anywhere on the call stack,
     proving zero [Effect.Unhandled] across all phases. *)
  let base_path = fresh_dir "masc_raw_systhread_orphan" in
  let temp_dir = fresh_dir "masc_raw_systhread_temp" in
  let config = Masc.Workspace.default_config base_path in
  let masc_root = Common.masc_dir_from_base_path ~base_path in
  let now = 1_800_000_000.0 in
  let old_ts = now -. (40.0 *. Masc_time_constants.day) in
  let prev_cfg_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.unsetenv "MASC_CONFIG_DIR";
  Fun.protect
    ~finally:(fun () ->
      match prev_cfg_dir with
      | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
      | None -> Unix.unsetenv "MASC_CONFIG_DIR")
    (fun () ->
       Fs_compat.mkdir_p masc_root;
       let dead_stage = Filename.concat masc_root ".private_jsonl_raw_01.stage" in
       Fs_compat.save_file dead_stage "orphan stage\n";
       let dead_agy_lock =
         Runtime_antigravity_home.keeper_prepare_lock_path
           ~runtime_root:masc_root ~owner_leaf:"rawdead"
       in
       Fs_compat.save_file dead_agy_lock "";
       let traces_dir = Filename.concat masc_root Workspace_init.traces_dirname in
       Fs_compat.mkdir_p traces_dir;
       let dead_trace_lock = Filename.concat traces_dir "raw-dead.checkpoint.lock" in
       Fs_compat.save_file dead_trace_lock "";
       let empty_review_dir =
         List.fold_left Filename.concat masc_root
           [ "keepers"; "completion-review-raw0001"; "continuity-requests" ]
       in
       Fs_compat.mkdir_p empty_review_dir;
       let ops_root =
         Filename.concat
           (Masc.Workspace.keepers_runtime_dir config)
           (Common.keeper_runtime_store_dirname Common.Keeper_shutdown_operations)
       in
       let empty_shutdown_dir = Filename.concat ops_root "_raw-empty" in
       Fs_compat.mkdir_p empty_shutdown_dir;
       let digest =
         match Masc.Keeper_meta_json.Snapshot_digest.of_string (String.make 64 'f') with
         | Ok d -> d
         | Error detail -> Alcotest.fail detail
       in
       let _op_id, settled_op_path =
         make_shutdown_op_fixture
           ~config
           ~old_ts
           ~keeper_name:"raw-settled-keeper"
           ~reason:Masc.Keeper_shutdown_types.Operator_stop_retain_meta
           ~phase:
             (Masc.Keeper_shutdown_types.Finalized
                { cleanup =
                    { Masc.Keeper_shutdown_types.settled_task_ids = []
                    ; pending_confirms_removed = 0
                    ; meta_snapshot_digest = digest
                    }
                ; meta_removed = false
                ; session_removed = false
                ; registry_unregistered = true
                ; completion = Masc.Keeper_shutdown_types.Completion_not_requested
                })
       in
       let exec_dir =
         Filename.concat (Filename.concat masc_root "verifier-executions") (String.make 64 '9')
       in
       let exec_file = Filename.concat exec_dir "journal.json" in
       Fs_compat.mkdir_p exec_dir;
       Fs_compat.save_file exec_file "{}";
       Unix.utimes exec_file old_ts old_ts;
       Unix.utimes exec_dir old_ts old_ts;
       let dead_temp_file = Filename.concat temp_dir "masc-claude-system-999991-raw.txt" in
       Fs_compat.save_file dead_temp_file "prompt";
       let outcome = Atomic.make None in
       let worker =
         Thread.create
           (fun () ->
              let res =
                try
                  let atomic = SM.sweep_atomic_orphans ~base_path in
                  let locks = SM.sweep_stale_durable_locks ~base_path in
                  let shutdown_res =
                    Masc.Keeper_shutdown_store.prune_terminal_and_empty_dirs
                      ~now
                      ~config
                      ~older_than_seconds:(30.0 *. Masc_time_constants.day)
                      ()
                  in
                  let review_dirs = SM.prune_empty_completion_review_dirs ~masc_root in
                  let verifier_res =
                    SM.prune_settled_verifier_executions ~now ~base_path ~days:30 ()
                  in
                  let temp =
                    SM.sweep_stale_temp_orphans
                      ~temp_dir
                      ~min_age_seconds:Masc_time_constants.day
                      ~is_pid_alive:(fun _ -> false)
                      ~now
                      ()
                  in
                  Ok (atomic, locks, shutdown_res, review_dirs, verifier_res, temp)
                with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn -> Error (Printexc.to_string exn)
              in
              Atomic.set outcome (Some res))
           ()
       in
       Thread.join worker;
       match Atomic.get outcome with
       | None -> Alcotest.fail "raw OS systhread did not record an outcome"
       | Some (Error detail) ->
         Alcotest.fail ("orphan hygiene raised inside raw OS systhread: " ^ detail)
       | Some (Ok (atomic, locks, shutdown_res, review_dirs, verifier_res, temp)) ->
         Alcotest.(check int) "atomic stage deleted" 1 atomic.deleted;
         Alcotest.(check int) "0 atomic failures" 0 (List.length atomic.failures);
         Alcotest.(check int) "2 stale locks removed (.prepare.lock + .checkpoint.lock)" 2 locks.removed;
         Alcotest.(check int) "0 lock failures" 0 locks.failed;
         (match shutdown_res with
          | Error err -> Alcotest.fail (Masc.Keeper_shutdown_store.error_to_string err)
          | Ok report ->
            Alcotest.(check int) "1 aged shutdown op pruned" 1 report.pruned_operations;
            Alcotest.(check int) "2 empty shutdown dirs pruned" 2 report.pruned_empty_dirs);
         Alcotest.(check int) "1 empty completion-review dir pruned" 1 review_dirs;
         (match verifier_res with
          | Error detail -> Alcotest.fail detail
          | Ok count -> Alcotest.(check int) "1 settled verifier execution pruned" 1 count);
         Alcotest.(check int) "1 dead temp file removed" 1 temp.removed_files;
         Alcotest.(check bool) "dead stage gone" false (Sys.file_exists dead_stage);
         Alcotest.(check bool) "dead .prepare.lock gone" false (Sys.file_exists dead_agy_lock);
         Alcotest.(check bool) "dead .checkpoint.lock gone" false (Sys.file_exists dead_trace_lock);
         Alcotest.(check bool) "empty completion-review dir gone" false
           (Sys.file_exists (Filename.dirname empty_review_dir));
         Alcotest.(check bool) "settled shutdown op gone" false (Sys.file_exists settled_op_path);
         Alcotest.(check bool) "empty shutdown dir gone" false (Sys.file_exists empty_shutdown_dir);
         Alcotest.(check bool) "settled verifier dir gone" false (Sys.file_exists exec_dir);
         Alcotest.(check bool) "dead temp file gone" false (Sys.file_exists dead_temp_file))

let () =
  Alcotest.run "server_runtime_startup_maintenance"
    [
      ( "orphan hygiene",
        [
          Alcotest.test_case "completion-review empty dirs and settled verifier executions" `Quick
            test_prune_empty_completion_review_and_verifier_executions;
          Alcotest.test_case "terminal shutdown operations and empty owner dirs" `Quick
            test_prune_terminal_shutdown_operations_and_empty_dirs;
          Alcotest.test_case "atomic orphan sweep unlinks dead stage and preserves flocked" `Quick
            test_sweep_atomic_orphans_removes_dead_stage_and_preserves_flocked;
          Alcotest.test_case "stale durable locks respect held locks and live targets" `Quick
            test_sweep_stale_durable_locks_respects_held_and_targets;
          Alcotest.test_case "stale temp orphans respect live pids, age barrier, and symlinks" `Quick
            test_sweep_stale_temp_orphans_pid_and_age_safety;
          Alcotest.test_case "startup_sweep_orphan_hygiene completes inside Systhread_host.run without Eio effects" `Quick
            test_startup_sweep_orphan_hygiene_runs_in_systhread_without_eio_effects;
          Alcotest.test_case "all orphan hygiene phases complete in raw OS systhread outside Eio" `Quick
            test_orphan_hygiene_phases_run_in_raw_os_systhread_outside_eio;
        ] );
      ( "physical containment",
        [ Alcotest.test_case "runtime root link refused" `Quick test_prune_refuses_linked_runtime_root;
          Alcotest.test_case "all layouts skip ancestor links" `Quick test_shared_prune_skips_ancestor_links;
          Alcotest.test_case "configured BasePath alias accepted" `Quick test_shared_prune_accepts_base_alias;
          Alcotest.test_case "flat prune leaves the fiber free" `Quick test_flat_prune_leaves_the_fiber_free ] );
      ( "prune_flat_jsonl_older_than",
        [
          Alcotest.test_case "populated trajectories dir prunes old files" `Quick
            test_prune_flat_jsonl_removes_old_files;
          Alcotest.test_case "numeric rotation siblings prune, others kept" `Quick
            test_prune_flat_jsonl_rotation_siblings;
        ] );
      ( "typesafeai exclusions",
        [
          Alcotest.test_case "unknown names come from the declarations" `Quick
            test_unknown_typesafeai_exclusions_come_from_declarations;
          Alcotest.test_case "unknown memory recall keepers come from the declarations" `Quick
            test_unknown_memory_recall_keepers_come_from_declarations;
        ] );
      ( "prune_shared_jsonl_stores",
        [
          Alcotest.test_case "keeper-scoped flat store list pinned" `Quick
            test_keeper_scoped_flat_store_list_is_ssot;
          Alcotest.test_case "production geometry round-trip" `Quick
            test_prune_shared_jsonl_stores_production_geometry;
        ] );
    ]
