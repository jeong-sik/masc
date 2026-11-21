module Original = Masc.Keeper_librarian_durable_capture
(** Tests for Keeper_memory_lane.

    The lane detaches post-turn memory work from the keeper turn lane:
    serialized within a keeper, independent across keepers, bounded, and
    leak-safe on a raising unit. *)

module Lane = Masc.Keeper_memory_lane
module Queue_refresh = Masc.Keeper_librarian_queue_refresh
module Queue_signal = Masc.Keeper_librarian_queue_signal

let base_path = Filename.concat (Filename.get_temp_dir_name ()) "test-memory-lane"

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name ])
  with
  | Ok meta -> meta
  | Error detail -> Alcotest.failf "keeper meta fixture failed: %s" detail
;;

let test_failed_official_turn_wakes_only_after_recording () =
  let module B = Masc.Keeper_turn_boundaries in
  let root = temp_dir "test-failed-official-wake-" in
  let env_key = Env_config.KeeperMemoryOs.librarian_env_key in
  let previous_env = Sys.getenv_opt env_key in
  Fun.protect ~finally:(fun () ->
    Unix.putenv env_key (Option.value previous_env ~default:"");
    Queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ());
    Config_dir_resolver.reset ();
    remove_tree root) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
  let config = Masc.Workspace.default_config root in
  ignore (Masc.Workspace.init config ~agent_name:None);
  Config_dir_resolver.reset ();
  let keeper_name = "failed-official" in
  let meta = make_meta keeper_name in
  let runtime_dir = Masc.Workspace.keepers_runtime_dir config in
  let wakes = ref [] in
  Queue_signal.install (fun ~base_path ~keeper_name ->
    let recorded = match B.read ~keepers_dir:runtime_dir ~keeper_id:keeper_name with
      | Error _ -> false
      | Ok lines -> List.exists (function
          | _, Ok {B.event=B.Turn_ended _;_} -> true
          | _ -> false) lines in
    wakes := (base_path,keeper_name,recorded) :: !wakes);
  let record_failure meta turn =
    let trace_id = Keeper_id.Trace_id.to_string meta.Masc.Keeper_meta_contract.runtime.trace_id in
    let session = Masc.Keeper_context_core.create_session ~session_id:trace_id
      ~base_dir:(Masc.Keeper_fs.session_store_path config) in
    Masc.Keeper_agent_run_finalize_response.record_errored_official_turn_boundary
      ~task_context:Masc.Keeper_turn_task_context.No_task ~config ~meta
      ~turn_ref:(Ids.Turn_ref.make ~trace_id ~absolute_turn:turn)
      ~session ~tool_observations:[] ~history_at_start:B.Continued_history
      ~restart_notice_pending:(Atomic.make false) in
  Unix.putenv env_key "true";
  record_failure meta 1;
  Alcotest.(check (list (triple string string bool)))
    "failed official turn wakes after its durable end exists"
    [config.base_path,keeper_name,true] (List.rev !wakes);
  Unix.putenv env_key "false";
  record_failure meta 2;
  Alcotest.(check int) "disabled Librarian is not woken" 1 (List.length !wakes);
  Unix.putenv env_key "true";
  let broken = make_meta "failed-append" in
  Fs_compat.mkdir_p (B.path_for_keepers_dir ~keepers_dir:runtime_dir ~keeper_id:broken.name);
  record_failure broken 1;
  Alcotest.(check int) "failed boundary append does not claim a completed source" 1 (List.length !wakes)
;;

(* Real lane cancellation must be followed by deletion under the same
   exclusion; a second purge cannot release the first one's ownership. *)
let test_purge_bracket_excludes_late_wakes () =
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "false") @@ fun () ->
  Lane.For_testing.reset ();
  let keeper_name = "purge-bracket" in
  let root = temp_dir "purge-bracket-" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    Eio_main.run @@ fun env ->
    Masc_test_deps.init_eio_clock env;
    Eio.Switch.run @@ fun sw ->
    Lane.init ~sw;
    let config = Masc.Workspace.default_config base_path in
    let started, start = Eio.Promise.create () in
    let never, _ = Eio.Promise.create () in
    let cancelled = ref false in
    ignore (Lane.submit ~base_path ~keeper_name (fun () ->
      Eio.Promise.resolve start ();
      try Eio.Promise.await never with Eio.Cancel.Cancelled _ as exn ->
        cancelled := true;
        ignore (Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
          ~commit:(fun _original ->
            Alcotest.fail "disabled observer reached model"));
        raise exn));
    Eio.Promise.await started;
    (match Domain.join (Domain.spawn (fun () ->
       Eio_main.run (fun _env ->
         Lane.with_librarian_purge ~base_path ~keeper_name (fun () ->
           Alcotest.fail "wrong-domain purge entered deletion")))) with
     | Error Lane.Purge_cancel_wrong_domain -> ()
     | _ -> Alcotest.fail "wrong-domain cancellation was not refused");
    let deleting, begin_delete = Eio.Promise.create () in
    let release, finish_delete = Eio.Promise.create () in
    let path = Filename.concat root "progress" in
    Out_channel.with_open_bin path (fun oc -> output_string oc "old");
    let purge = Eio.Fiber.fork_promise ~sw (fun () ->
      Lane.with_librarian_purge ~base_path ~keeper_name (fun () ->
        Alcotest.(check bool) "old work exited before deletion" true !cancelled;
        Alcotest.(check bool) "old work published its final observation" true
          (Option.is_some (Queue_refresh.last_measurement ~config ~keeper_name));
        Queue_refresh.forget_measurement ~config ~keeper_name;
        Sys.remove path;
        Eio.Promise.resolve begin_delete ();
        Eio.Promise.await release)) in
    Eio.Promise.await deleting;
    (match Lane.with_librarian_purge ~base_path ~keeper_name (fun () ->
       Alcotest.fail "concurrent purge entered deletion") with
     | Error Lane.Purge_already_in_progress -> ()
     | _ -> Alcotest.fail "concurrent purge was not refused");
    (match Lane.submit ~base_path ~keeper_name (fun () ->
       Out_channel.with_open_bin path (fun oc -> output_string oc "late")) with
     | Lane.Dropped -> ()
     | _ -> Alcotest.fail "late wake crossed purge exclusion");
    Eio.Fiber.yield ();
    Alcotest.(check bool) "late wake did not recreate deleted progress" false (Sys.file_exists path);
    Alcotest.(check bool) "old observation cleared after quiescence" true
      (Option.is_none (Queue_refresh.last_measurement ~config ~keeper_name));
    Eio.Promise.resolve finish_delete ();
    (match Eio.Promise.await purge with
     | Ok (Ok ()) -> ()
     | _ -> Alcotest.fail "purge did not finish");
    (match Lane.submit ~base_path ~keeper_name (fun () ->
       Out_channel.with_open_bin path (fun oc -> output_string oc "new")) with
     | Lane.Submitted -> ()
     | _ -> Alcotest.fail "purge exclusion remained after deletion");
    Lane.For_testing.await_idle ~base_path ~keeper_name;
    Alcotest.(check bool) "new identity can write after purge" true (Sys.file_exists path))
;;

let test_durable_drain_publishes_scoped_health () =
  let root = temp_dir "test-durable-health-" in
  let env_key = Env_config.KeeperMemoryOs.librarian_env_key in
  let prior = Sys.getenv_opt env_key in
  Fun.protect ~finally:(fun () ->
    Unix.putenv env_key (Option.value ~default:"" prior);
    Config_dir_resolver.reset ();
    remove_tree root)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Masc_test_deps.init_eio_clock env;
      let config = Masc.Workspace.default_config root in
      ignore (Masc.Workspace.init config ~agent_name:None);
      Config_dir_resolver.reset ();
      (* The durable drain lists the keepers directory before it reads this
         Keeper's metadata, so a workspace with no keepers directory stops on
         the unreadable listing and never reaches the missing metadata this
         test observes. The directory exists wherever a Keeper is configured. *)
      Fs_compat.mkdir_p (Config_dir_resolver.keepers_dir_for_base_path ~base_path:root);
      let keeper_name = "health-observed" in
      let run () = ignore (Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
        ~commit:(fun _original ->
          Alcotest.fail "empty history must not call the model")) in
      let observed () =
        match Queue_refresh.last_measurement ~config ~keeper_name with
        | Some value -> value
        | None -> Alcotest.fail "durable drain did not publish an observation"
      in
      let log_cursor () = (Log.Ring.bounds ()).total - 1 in
      let keeper_warnings_since since_seq =
        Log.Ring.recent ~since_seq ~module_filter:"Keeper" ~order:`Oldest_first ()
        |> List.filter (fun (entry : Log.Ring.entry) -> entry.level = Log.Warn)
        |> List.map (fun (entry : Log.Ring.entry) -> entry.message)
      in
      Unix.putenv env_key "false";
      run ();
      (match (observed ()).last_pass, (observed ()).unread with
       | Queue_refresh.Off, None -> ()
       | _ -> Alcotest.fail "disabled drain must not measure lag");
      Unix.putenv env_key "true";
      let seq0 = log_cursor () in
      run ();
      (match (observed ()).last_pass, (observed ()).unread with
       | Queue_refresh.Stopped Masc.Keeper_librarian_durable_consumer.Keeper_meta_absent, None -> ()
       | _ -> Alcotest.fail "missing metadata must replace the old observation");
      Alcotest.(check (list string))
        "missing metadata logs drain stop once without redundant unread warning"
        [ "durable Librarian range not consumed: keeper metadata is absent" ]
        (keeper_warnings_since seq0);
      let seq1 = log_cursor () in
      run ();
      Alcotest.(check (list string))
        "repeated missing metadata pass suppresses duplicate warning"
        []
        (keeper_warnings_since seq1);
      (* Effective metadata requires both its runtime snapshot and declaration.
         Create the real profile before asking the durable reader to use it. *)
      let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:root in
      Fs_compat.mkdir_p keepers_dir;
      let profile_path = Filename.concat keepers_dir (keeper_name ^ ".toml") in
      Out_channel.with_open_bin profile_path
        (fun oc -> Printf.fprintf oc
          "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\nsandbox_image = \"base\"\n"
          keeper_name "test durable health" "docker");
      Masc.Keeper_types_profile.invalidate_keeper_profile_snapshots ();
      (match Masc.Keeper_meta_store.replace_snapshot config (make_meta keeper_name) with
       | Ok () -> () | Error detail -> Alcotest.fail detail);
      run ();
      (match (observed ()).last_pass, (observed ()).unread with
       | Queue_refresh.Drained, Some { atoms = 0; official = 0 } -> ()
       | _ -> Alcotest.fail "empty real source must publish drained with zero lag");
      Unix.unlink (Masc.Keeper_types_profile.keeper_meta_path config keeper_name);
      (* Keeper_meta_store keeps no read cache (its only table is the
         problem-report dedup), so the next pass reads the absence from
         disk. The pre-merge draft called an invalidate_cached_snapshot
         that never existed in the store. *)
      let seq2 = log_cursor () in
      run ();
      Alcotest.(check (list string))
        "newly missing metadata after recovery logs once again"
        [ "durable Librarian range not consumed: keeper metadata is absent" ]
        (keeper_warnings_since seq2);
      let other = Masc.Workspace.default_config (Filename.concat root "other-runtime") in
      Alcotest.(check bool) "same name in another runtime has no borrowed observation" true
        (Option.is_none (Queue_refresh.last_measurement ~config:other ~keeper_name));
      Unix.putenv env_key "false";
      run ();
      (match (observed ()).last_pass, (observed ()).unread with
       | Queue_refresh.Off, None -> ()
       | _ -> Alcotest.fail "off must replace the earlier successful count"))
;;

(* RFC librarian-lifecycle stage 4, item 2: the boot scan submits the durable
   catch-up for the Keepers autoboot did not launch. *)
let test_boot_catchup_names_only_the_unlaunched () =
  Alcotest.(check (list string))
    "persisted order kept, launched removed"
    [ "a"; "c" ]
    (Queue_refresh.unlaunched_keeper_names
       ~persisted:[ "a"; "b"; "c" ]
       ~launched:[ "b"; "not-persisted" ]);
  Alcotest.(check (list string))
    "nothing launched: every persisted Keeper"
    [ "a"; "b" ]
    (Queue_refresh.unlaunched_keeper_names ~persisted:[ "a"; "b" ] ~launched:[]);
  Alcotest.(check (list string))
    "nothing persisted: nobody"
    []
    (Queue_refresh.unlaunched_keeper_names ~persisted:[] ~launched:[ "a" ])
;;

let test_boot_catchup_submits_one_unit_per_unlaunched_keeper () =
  Lane.For_testing.reset ();
  let root = temp_dir "test-boot-catchup-" in
  Fun.protect
    ~finally:(fun () ->
      Config_dir_resolver.reset ();
      Lane.For_testing.reset ();
      remove_tree root)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Masc_test_deps.init_eio_clock env;
       let config = Masc.Workspace.default_config root in
       ignore (Masc.Workspace.init config ~agent_name:None);
       Config_dir_resolver.reset ();
       Eio.Switch.run @@ fun sw ->
       Lane.init ~sw;
       let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:root in
       let candidate = Masc.Keeper_memory_os_types.observed
         ~claim:"pending explicit observation" ~category:Fact ~now:100.
         ~origin:{kind=Authored;trace_id="boot"} in
       List.iter (fun keeper_id ->
         match Masc.Keeper_memory_admission_queue.append ~keepers_dir ~keeper_id
           ~request_id:"boot-candidate" candidate with
         | Ok _ -> () | Error error -> Alcotest.fail
             (Masc.Keeper_memory_admission_queue.append_error_to_string error)) ["a";"queue-only"];
       let submitted =
         Queue_refresh.submit_durable_for_unlaunched
           ~base_path:root
           ~persisted:[ "a"; "b"; "c" ]
           ~launched:[ "b" ]
       in
       Alcotest.(check (list string))
         "submitted for the unlaunched"
         [ "a"; "c"; "queue-only" ]
         submitted;
       (* A unit that finds nothing unread ends at once, so the entry, not
          the count, is the evidence that a submission reached the lane. *)
       let reached_lane name =
         Option.is_some (Lane.For_testing.pending ~base_path:root ~keeper_name:name)
       in
       Alcotest.(check bool) "a reached the lane" true (reached_lane "a");
       Alcotest.(check bool) "b was launched: nothing submitted" false (reached_lane "b");
       Alcotest.(check bool) "c reached the lane" true (reached_lane "c");
       Alcotest.(check bool) "candidate-only keeper reached the lane" true (reached_lane "queue-only");
       Lane.For_testing.await_idle ~base_path:root ~keeper_name:"a";
       Lane.For_testing.await_idle ~base_path:root ~keeper_name:"c";
       Lane.For_testing.await_idle ~base_path:root ~keeper_name:"queue-only";
       match Masc.Keeper_memory_admission_queue.read_pending ~keepers_dir ~keeper_id:"queue-only" with
       | Ok (Some _) -> ()
       | Ok None -> Alcotest.fail "missing metadata consumed pending input"
       | Error detail -> Alcotest.fail detail)
;;

let () =
  Alcotest.run
    "keeper_memory_lane_librarian_durable"
    [ ( "lane"
      , [ Alcotest.test_case "durable drain publishes scoped health" `Quick
            test_durable_drain_publishes_scoped_health
        ; Alcotest.test_case "failed official boundary wakes only after durable append" `Quick
            test_failed_official_turn_wakes_only_after_recording
        ; Alcotest.test_case
            "purge bracket excludes late wakes and concurrent purge"
            `Quick test_purge_bracket_excludes_late_wakes
        ; Alcotest.test_case
            "boot catch-up names only the unlaunched"
            `Quick
            test_boot_catchup_names_only_the_unlaunched
        ; Alcotest.test_case
            "boot catch-up submits one unit per unlaunched keeper"
            `Quick
            test_boot_catchup_submits_one_unit_per_unlaunched_keeper
        ] )
    ]
;;
