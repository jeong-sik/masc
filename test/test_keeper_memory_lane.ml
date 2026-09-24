(** Tests for Keeper_memory_lane (RFC-0257).

    The lane detaches post-turn memory work from the keeper turn lane:
    serialized within a keeper, independent across keepers, bounded, and
    leak-safe on a raising unit. *)

module Lane = Masc.Keeper_memory_lane
module Keeper_lane = Masc.Keeper_lane
module Post_turn_memory = Masc.Keeper_agent_run_post_turn_memory
module Queue_refresh = Masc.Keeper_librarian_queue_refresh
module Queue_signal = Masc.Keeper_librarian_queue_signal

exception Test_boom
exception Cancel_lane_test

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

let run_post_turn
  ~checkpoint_owner
  ~config
  ~(meta : Masc.Keeper_meta_contract.keeper_meta)
  ~turn
  =
  Post_turn_memory.run
    ~config
    ~meta
    ~turn
    ~agent_core_turn_count:1
    ~checkpoint_owner
    ~post_turn_t0:(Time_compat.now ())
    ~inference_telemetry:None
    ()
;;

let test_either_checkpoint_owner_wakes_the_durable_consumer () =
  Lane.For_testing.reset ();
  let root = temp_dir "test-post-turn-owner-" in
  let env_key = Env_config.KeeperMemoryOs.librarian_env_key in
  let previous_env = Sys.getenv_opt env_key in
  Fun.protect
    ~finally:(fun () ->
      (match previous_env with
       | Some value -> Unix.putenv env_key value
       | None -> Unix.putenv env_key "");
      Queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ());
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
       Unix.putenv env_key "true";
       let wakes = ref [] in
       Queue_signal.install (fun ~base_path ~keeper_name ->
         wakes := (base_path, keeper_name) :: !wakes);
       let core_name = "agent-core-owner" in
       let core_meta = make_meta core_name in
       run_post_turn
         ~checkpoint_owner:Runtime_execution.Masc_agent_core
         ~config
         ~meta:core_meta
         ~turn:1;
       Alcotest.(check (list (pair string string)))
         "Agent Core emits one durable wake"
         [ config.base_path, core_name ]
         (List.rev !wakes);
       let official_name = "official-client-owner" in
       let official_meta = make_meta official_name in
       Alcotest.(check (option int))
         "official-client lane has no work before its first turn"
         None
         (Lane.For_testing.pending
            ~base_path:config.base_path
            ~keeper_name:official_name);
       run_post_turn
         ~checkpoint_owner:Runtime_execution.Official_client
         ~config
         ~meta:official_meta
         ~turn:1;
       Alcotest.(check (list (pair string string)))
         "official client emits one durable wake as well"
         [ config.base_path, core_name; config.base_path, official_name ]
         (List.rev !wakes);
       Unix.putenv env_key "false";
       run_post_turn
         ~checkpoint_owner:Runtime_execution.Official_client
         ~config
         ~meta:official_meta
         ~turn:2;
       Alcotest.(check (list (pair string string)))
         "a disabled librarian wakes nothing"
         [ config.base_path, core_name; config.base_path, official_name ]
         (List.rev !wakes))
;;

(* No executor switch set -> submit runs inline so no work is lost. *)
let test_inline_when_uninitialized () =
  Lane.For_testing.reset ();
  let ran = ref false in
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" (fun () -> ran := true)
  in
  Alcotest.(check bool) "unit ran inline" true !ran;
  match outcome with
  | Lane.Ran_inline -> ()
  | Lane.Submitted -> Alcotest.fail "expected Ran_inline, got Submitted"
  | Lane.Coalesced -> Alcotest.fail "expected Ran_inline, got Coalesced"
  | Lane.Dropped -> Alcotest.fail "expected Ran_inline, got Dropped"
;;

(* A raising unit in the inline path is contained and returns Ran_inline. *)
let test_inline_contains_raise () =
  Lane.For_testing.reset ();
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" (fun () -> raise Test_boom)
  in
  match outcome with
  | Lane.Ran_inline -> ()
  | Lane.Submitted -> Alcotest.fail "expected Ran_inline, got Submitted"
  | Lane.Coalesced -> Alcotest.fail "expected Ran_inline, got Coalesced"
  | Lane.Dropped -> Alcotest.fail "expected Ran_inline, got Dropped"
;;

(* Two units for the same keeper run one after another: the second only starts
   after the first releases the keeper's mutex. *)
let test_serializes_within_keeper () =
  Lane.For_testing.reset ();
  let order = ref [] in
  let add s = order := s :: !order in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_started, set_started = Eio.Promise.create () in
      let p_release, set_release = Eio.Promise.create () in
      let oa =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          add "a-start";
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          add "a-end")
      in
      Eio.Promise.await p_started;
      let ob =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () -> add "b")
      in
      (* Let B attempt (and fail) to acquire the keeper mutex held by A. *)
      Eio.Fiber.yield ();
      add "before-release";
      Eio.Promise.resolve set_release ();
      (match oa with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "unit A not submitted");
      match ob with
      | Lane.Submitted -> ()
      | _ -> Alcotest.fail "unit B not submitted"));
  Alcotest.(check (list string))
    "B serialized behind A"
    [ "a-start"; "before-release"; "a-end"; "b" ]
    (List.rev !order)
;;

(* A unit for one keeper does not block a unit for another keeper. *)
let test_independent_across_keepers () =
  Lane.For_testing.reset ();
  let order = ref [] in
  let add s = order := s :: !order in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_started, set_started = Eio.Promise.create () in
      let p_release, set_release = Eio.Promise.create () in
      let _ =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          add "k1")
      in
      Eio.Promise.await p_started;
      let _ =
        Lane.submit ~base_path ~keeper_name:"k2" (fun () -> add "k2")
      in
      (* k2 runs to completion while k1 is still holding its own lane. *)
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      Alcotest.(check bool) "k2 ran while k1 blocked" true (List.mem "k2" !order);
      Eio.Promise.resolve set_release ()));
  Alcotest.(check (list string)) "k2 before k1" [ "k2"; "k1" ] (List.rev !order)
;;

(* Librarian saturation keeps one running unit and one overwriteable latest
   snapshot. Every submit returns immediately; only the newest pending snapshot
   evaluates after the blocker. *)
let test_librarian_saturation_coalesces_latest () =
  Lane.For_testing.reset ();
  let ring_before =
    match Log.Ring.recent ~limit:1 () with
    | entry :: _ -> entry.Log.Ring.seq
    | [] -> 0
  in
  let evaluated = ref [] in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let running =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release;
          evaluated := "running" :: !evaluated)
      in
      Eio.Promise.await started;
      let snapshot trace generation messages () =
        evaluated :=
          Printf.sprintf "%s:%d:%s" trace generation (String.concat "," messages)
          :: !evaluated
      in
      let stale =
        Lane.submit ~base_path ~keeper_name:"k1"
          (snapshot "trace-stale" 1 [ "stale" ])
      in
      let newer =
        Lane.submit ~base_path ~keeper_name:"k1"
          (snapshot "trace-newer" 2 [ "newer" ])
      in
      let newest =
        Lane.submit ~base_path ~keeper_name:"k1"
          (snapshot "trace-newest" 3 [ "newest-a"; "newest-b" ])
      in
      (match running, stale, newer, newest with
       | Lane.Submitted, Lane.Submitted, Lane.Coalesced, Lane.Coalesced -> ()
       | _ -> Alcotest.fail "unexpected Librarian coalescing outcomes");
      (match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
       | Some 2 -> ()
       | Some n -> Alcotest.failf "running+latest bound should be 2, got %d" n
       | None -> Alcotest.fail "missing Librarian lane entry");
      Eio.Promise.resolve set_release ()));
  Alcotest.(check (list string))
    "only running and newest snapshot evaluate"
    [ "running"; "trace-newest:3:newest-a,newest-b" ]
    (List.rev !evaluated);
  (* The coalesced-path message must state the lane without the fabricated
     "pending=2" literal the old WARN hardcoded (2026-08-27 audit: 69
     identical messages reporting a count no code tracked). *)
  let coalesce_rows =
    Log.Ring.recent ~since_seq:ring_before ()
    |> List.filter (fun (row : Log.Ring.entry) ->
           String.equal row.message
             "memory lane coalesced latest snapshot (lane=librarian): \
              replacing superseded post-turn memory unit")
  in
  Alcotest.(check bool)
    "coalesced units each log the honest lane message" true
    (List.length coalesce_rows = 2);
  let contains_substring hay needle =
    let hl = String.length hay and nl = String.length needle in
    let rec from i =
      i + nl <= hl
      && (String.sub hay i nl = needle || from (i + 1))
    in
    from 0
  in
  let lane_rows_with_fabricated_count =
    Log.Ring.recent ~since_seq:ring_before ()
    |> List.filter (fun (row : Log.Ring.entry) ->
           String.equal row.module_name "Keeper"
           && contains_substring row.message "memory lane")
    |> List.exists (fun (row : Log.Ring.entry) ->
           contains_substring row.message "pending=2")
  in
  Alcotest.(check bool)
    "no fabricated pending count survives" true
    (not lane_rows_with_fabricated_count);
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked after coalesced drain: %d" n
  | None -> Alcotest.fail "Librarian lane entry missing"
;;

(* A unit that raises releases the mutex and the pending slot, so the lane
   recovers and later units run. *)
let test_releases_on_raise () =
  Lane.For_testing.reset ();
  let latest_ran = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let first =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release;
          raise Test_boom)
      in
      Eio.Promise.await started;
      let latest =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          latest_ran := true)
      in
      (match first, latest with
       | Lane.Submitted, Lane.Submitted -> ()
       | _ -> Alcotest.fail "raise fixture submissions were not accepted");
      Eio.Promise.resolve set_release ()));
  Alcotest.(check bool) "latest runs after raising unit" true !latest_ran;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked: %d" n
  | None -> Alcotest.fail "keeper entry missing"
;;

(* Cancellation during shutdown releases both the mutex and the pending slot. *)
let test_releases_on_cancel () =
  Lane.For_testing.reset ();
  let latest_ran = ref false in
  (try
     Eio_main.run (fun _env ->
       Eio.Switch.run (fun sw ->
         Lane.init ~sw;
         let started, set_started = Eio.Promise.create () in
         let never, _set_never = Eio.Promise.create () in
         let outcome =
           Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
             Eio.Promise.resolve set_started ();
             Eio.Promise.await never)
         in
         let latest =
           Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
             latest_ran := true)
         in
         (match outcome with
          | Lane.Submitted -> ()
          | Lane.Coalesced -> Alcotest.fail "first cancel unit unexpectedly coalesced"
          | Lane.Ran_inline -> Alcotest.fail "cancel test unexpectedly ran inline"
          | Lane.Dropped -> Alcotest.fail "cancel test unexpectedly dropped");
         (match latest with
          | Lane.Submitted -> ()
          | Lane.Coalesced -> Alcotest.fail "first latest unit unexpectedly coalesced"
          | Lane.Ran_inline -> Alcotest.fail "latest cancel unit unexpectedly ran inline"
          | Lane.Dropped -> Alcotest.fail "latest cancel unit unexpectedly dropped");
         Eio.Promise.await started;
         Eio.Switch.fail sw Cancel_lane_test))
   with
   | Cancel_lane_test -> ());
  Alcotest.(check bool) "latest did not run after switch cancel" false !latest_ran;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked after cancel: %d" n
  | None -> Alcotest.fail "keeper entry missing after cancel"
;;

(* A Keeper purge is the one thing that stops a unit early (RFC
   librarian-lifecycle section 8). It cancels the running unit, waits until
   the lane has exited, and leaves no fence behind: the next submission is
   accepted and runs. *)
let test_purge_cancels_running_unit_and_leaves_no_fence () =
  Lane.For_testing.reset ();
  let cancelled = ref false in
  let after_purge_ran = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let never, _set_never = Eio.Promise.create () in
      (match
         Lane.submit
           ~base_path
           ~keeper_name:"purged-owner"
           (fun () ->
              Eio.Promise.resolve set_started ();
              try Eio.Promise.await never with
              | Eio.Cancel.Cancelled _ as exn ->
                cancelled := true;
                raise exn)
       with
       | Lane.Submitted -> ()
       | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
         Alcotest.fail "purge fixture was not submitted");
      Eio.Promise.await started;
      (match
         Lane.cancel_and_await_librarian ~base_path ~keeper_name:"purged-owner"
       with
       | Ok () -> ()
       | Error error -> Alcotest.fail (Lane.purge_cancel_error_to_string error));
      Alcotest.(check bool) "the running unit was cancelled" true !cancelled;
      Alcotest.(check (option int))
        "purge left no pending work"
        (Some 0)
        (Lane.For_testing.pending ~base_path ~keeper_name:"purged-owner");
      let finished, set_finished = Eio.Promise.create () in
      (match
         Lane.submit
           ~base_path
           ~keeper_name:"purged-owner"
           (fun () ->
              after_purge_ran := true;
              Eio.Promise.resolve set_finished ())
       with
       | Lane.Submitted -> ()
       | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
         Alcotest.fail "submission after purge was not accepted");
      Eio.Promise.await finished;
      Alcotest.(check bool) "a unit submitted after purge runs" true !after_purge_ran))
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
        Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
          ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
            Alcotest.fail "disabled observer reached model");
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

let test_purge_bracket_releases_on_failure_and_cancellation () =
  Lane.For_testing.reset ();
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Lane.init ~sw;
  let keeper_name = "purge-failure" in
  (match Lane.with_librarian_purge ~base_path ~keeper_name (fun () -> Error "delete failed") with
   | Ok (Error "delete failed") -> ()
   | _ -> Alcotest.fail "deletion result was changed");
  (match Lane.with_librarian_purge ~base_path ~keeper_name (fun () -> raise Test_boom) with
   | exception Test_boom -> ()
   | _ -> Alcotest.fail "deletion exception was swallowed");
  let entered, enter = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  let purge = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun cc ->
      Lane.with_librarian_purge ~base_path ~keeper_name (fun () ->
        Eio.Promise.resolve enter cc;
        Eio.Promise.await never))) in
  let cc = Eio.Promise.await entered in
  Eio.Cancel.cancel cc Cancel_lane_test;
  (match Eio.Promise.await purge with
   | Error (Eio.Cancel.Cancelled _) -> ()
   | _ -> Alcotest.fail "purge cancellation was swallowed");
  let ran = ref false in
  (match Lane.submit ~base_path ~keeper_name (fun () -> ran := true) with
   | Lane.Submitted -> ()
   | _ -> Alcotest.fail "failed purge left an exclusion behind");
  Lane.For_testing.await_idle ~base_path ~keeper_name;
  Alcotest.(check bool) "lane accepts after failed/cancelled deletion" true !ran
;;

(* A cancellation lookup for an unused keeper creates no entry. *)
let test_purge_with_nothing_running_returns_at_once () =
  Lane.For_testing.reset ();
  (match Lane.cancel_and_await_librarian ~base_path ~keeper_name:"never-ran" with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Lane.purge_cancel_error_to_string error));
  Alcotest.(check (option int))
    "purge did not create a lane entry"
    None
    (Lane.For_testing.pending ~base_path ~keeper_name:"never-ran")
;;

(* Submitting against a finished executor switch must not leak the pending
   reservation. Eio.Fiber.fork does not raise to the caller for an off switch, so
   the lane needs its own executor-switch release fallback. *)
let test_finished_switch_drops_without_leak () =
  Lane.For_testing.reset ();
  let finished_sw = ref None in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      finished_sw := Some sw));
  let sw =
    match !finished_sw with
    | Some sw -> sw
    | None -> Alcotest.fail "missing captured switch"
  in
  Lane.init ~sw;
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" (fun () -> raise Test_boom)
  in
  (match outcome with
   | Lane.Dropped -> ()
   | Lane.Submitted -> Alcotest.fail "expected Dropped, got Submitted"
   | Lane.Coalesced -> Alcotest.fail "expected Dropped, got Coalesced"
   | Lane.Ran_inline -> Alcotest.fail "expected Dropped, got Ran_inline");
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 ->
    (* The dropped unit's lane already exited, so a purge has nothing to wait
       for and must not hang on it. *)
    (match
       Eio_main.run (fun _env ->
         Lane.cancel_and_await_librarian ~base_path ~keeper_name:"k1")
     with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf
         "finished-switch drop blocked a purge: %s"
         (Lane.purge_cancel_error_to_string error))
  | Some n -> Alcotest.failf "pending leaked after finished switch submit: %d" n
  | None -> Alcotest.fail "keeper entry missing after finished switch submit"
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
      let keeper_name = "health-observed" in
      let run () = Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
        ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
          Alcotest.fail "empty history must not call the model") in
      let observed () =
        match Queue_refresh.last_measurement ~config ~keeper_name with
        | Some value -> value
        | None -> Alcotest.fail "durable drain did not publish an observation"
      in
      Unix.putenv env_key "false";
      run ();
      (match (observed ()).last_pass, (observed ()).unread with
       | Queue_refresh.Off, None -> ()
       | _ -> Alcotest.fail "disabled drain must not measure lag");
      Unix.putenv env_key "true";
      run ();
      (match (observed ()).last_pass, (observed ()).unread with
       | Queue_refresh.Stopped Masc.Keeper_librarian_durable_consumer.Keeper_meta_absent, None -> ()
       | _ -> Alcotest.fail "missing metadata must replace the old observation");
      (* Effective metadata requires both its runtime snapshot and declaration.
         Create the real profile before asking the durable reader to use it. *)
      let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:root in
      Fs_compat.mkdir_p keepers_dir;
      Out_channel.with_open_bin (Filename.concat keepers_dir (keeper_name ^ ".toml"))
        (fun oc -> Printf.fprintf oc
          "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\nsandbox_image = \"masc-sandbox:general\"\n"
          keeper_name "test durable health" "docker");
      Masc.Keeper_types_profile.invalidate_keeper_profile_defaults_cache keeper_name;
      (match Masc.Keeper_meta_store.replace_snapshot config (make_meta keeper_name) with
       | Ok () -> () | Error detail -> Alcotest.fail detail);
      run ();
      (match (observed ()).last_pass, (observed ()).unread with
       | Queue_refresh.Drained, Some { atoms = 0; official = 0 } -> ()
       | _ -> Alcotest.fail "empty real source must publish drained with zero lag");
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
       let submitted =
         Queue_refresh.submit_durable_for_unlaunched
           ~base_path:root
           ~persisted:[ "a"; "b"; "c" ]
           ~launched:[ "b" ]
       in
       Alcotest.(check (list string))
         "submitted for the unlaunched"
         [ "a"; "c" ]
         submitted;
       (* A unit that finds nothing unread ends at once, so the entry, not
          the count, is the evidence that a submission reached the lane. *)
       let reached_lane name =
         Option.is_some (Lane.For_testing.pending ~base_path:root ~keeper_name:name)
       in
       Alcotest.(check bool) "a reached the lane" true (reached_lane "a");
       Alcotest.(check bool) "b was launched: nothing submitted" false (reached_lane "b");
       Alcotest.(check bool) "c reached the lane" true (reached_lane "c");
       Lane.For_testing.await_idle ~base_path:root ~keeper_name:"a";
       Lane.For_testing.await_idle ~base_path:root ~keeper_name:"c")
;;

(* The purge cancels the running catch-up and discards wakes while it runs.
   A stopped Keeper ends no turn, so the backlog is put back on the lane after
   every purge exit: applied, refused (for unread atoms), and raised. The
   durable unit publishes a measurement whether or not the Librarian is
   enabled, so the measurement is the evidence that the unit ran. *)
let test_purge_resubmits_the_librarian_on_every_exit () =
  Lane.For_testing.reset ();
  let root = temp_dir "test-purge-catchup-" in
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
       let caught_up keeper_name =
         Lane.For_testing.await_idle ~base_path:root ~keeper_name;
         Option.is_some (Queue_refresh.last_measurement ~config ~keeper_name)
       in
       let purge keeper_name action =
         Queue_refresh.with_purge_then_catch_up ~base_path:root ~keeper_name action
       in
       Alcotest.(check bool) "no measurement before any purge" false
         (Option.is_some (Queue_refresh.last_measurement ~config ~keeper_name:"applied"));
       (match purge "applied" (fun () -> Ok ()) with
        | Ok (Ok ()) -> ()
        | _ -> Alcotest.fail "applied purge result was changed");
       Alcotest.(check bool) "applied purge resubmits" true (caught_up "applied");
       (match purge "refused" (fun () -> Error "unread atoms present") with
        | Ok (Error "unread atoms present") -> ()
        | _ -> Alcotest.fail "refused purge result was changed");
       Alcotest.(check bool) "refused purge resubmits" true (caught_up "refused");
       (match purge "raised" (fun () -> raise Test_boom) with
        | exception Test_boom -> ()
        | _ -> Alcotest.fail "purge exception was swallowed");
       Alcotest.(check bool) "raised purge resubmits" true (caught_up "raised"))
;;

let () =
  Alcotest.run
    "keeper_memory_lane"
    [ ( "lane"
      , [ Alcotest.test_case "durable drain publishes scoped health" `Quick
            test_durable_drain_publishes_scoped_health
        ; Alcotest.test_case
            "either checkpoint owner wakes the durable consumer"
            `Quick
            test_either_checkpoint_owner_wakes_the_durable_consumer
        ; Alcotest.test_case
            "inline when uninitialized"
            `Quick
            test_inline_when_uninitialized
        ; Alcotest.test_case
            "inline contains raise"
            `Quick
            test_inline_contains_raise
        ; Alcotest.test_case
            "serializes within keeper"
            `Quick
            test_serializes_within_keeper
        ; Alcotest.test_case
            "independent across keepers"
            `Quick
            test_independent_across_keepers
        ; Alcotest.test_case
            "librarian saturation coalesces latest"
            `Quick
            test_librarian_saturation_coalesces_latest
        ; Alcotest.test_case "releases on raise" `Quick test_releases_on_raise
        ; Alcotest.test_case "releases on cancel" `Quick test_releases_on_cancel
        ; Alcotest.test_case
            "purge cancels the running unit and leaves no fence"
            `Quick
            test_purge_cancels_running_unit_and_leaves_no_fence
        ; Alcotest.test_case
            "purge bracket excludes late wakes and concurrent purge"
            `Quick test_purge_bracket_excludes_late_wakes
        ; Alcotest.test_case
            "purge bracket releases on failure and cancellation"
            `Quick test_purge_bracket_releases_on_failure_and_cancellation
        ; Alcotest.test_case
            "purge with nothing running returns at once"
            `Quick
            test_purge_with_nothing_running_returns_at_once
        ; Alcotest.test_case
            "boot catch-up names only the unlaunched"
            `Quick
            test_boot_catchup_names_only_the_unlaunched
        ; Alcotest.test_case
            "boot catch-up submits one unit per unlaunched keeper"
            `Quick
            test_boot_catchup_submits_one_unit_per_unlaunched_keeper
        ; Alcotest.test_case
            "purge resubmits the Librarian on every exit"
            `Quick
            test_purge_resubmits_the_librarian_on_every_exit
        ; Alcotest.test_case
            "finished switch drops without leak"
            `Quick
            test_finished_switch_drops_without_leak
        ] )
    ]
;;
