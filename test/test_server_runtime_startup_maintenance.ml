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

let () =
  Alcotest.run "server_runtime_startup_maintenance"
    [
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
