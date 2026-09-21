(** Tests for Keeper_memory_lane (RFC-0257).

    The lane detaches post-turn memory work from the keeper turn lane:
    serialized within a keeper, independent across keepers, bounded, and
    leak-safe on a raising unit. *)

module Lane = Masc.Keeper_memory_lane
module Keeper_lane = Masc.Keeper_lane
module Librarian_runtime = Masc.Keeper_librarian_runtime
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
       let direct_runs = ref 0 in
       let wakes = ref [] in
       Queue_signal.install (fun ~base_path ~keeper_name ->
         wakes := (base_path, keeper_name) :: !wakes);
       let core_name = "agent-core-owner" in
       let core_meta = make_meta core_name in
       let core_trace_id =
         Keeper_id.Trace_id.to_string core_meta.runtime.trace_id
       in
       Queue_refresh.remember_turn
         ~base_path:config.base_path
         ~keeper_name:core_name
         ~trace_id:core_trace_id
         (fun ~meta:_ _ -> incr direct_runs; Queue_refresh.Entered);
       run_post_turn
         ~checkpoint_owner:Runtime_execution.Masc_agent_core
         ~config
         ~meta:core_meta
         ~turn:1;
       Alcotest.(check bool)
         "Agent Core handoff attempts pending direct evidence"
         true
         (Queue_refresh.For_testing.attempt_remembered
            ~base_path:config.base_path
            ~keeper_name:core_name
            ~trace_id:core_trace_id
            ~meta:core_meta
            ~sources_changed:false
            ~trigger:Librarian_runtime.Queue_changed);
       Alcotest.(check int) "Agent Core runs the pending direct producer once" 1 !direct_runs;
       Alcotest.(check bool)
         "Agent Core retires direct evidence after the handoff attempt"
         false
         (Queue_refresh.For_testing.attempt_remembered
            ~base_path:config.base_path
            ~keeper_name:core_name
            ~trace_id:core_trace_id
            ~meta:core_meta
            ~sources_changed:true
            ~trigger:Librarian_runtime.Queue_changed);
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
       Unix.putenv env_key "false";
       Alcotest.(check bool)
         "official client hands over no direct evidence"
         false
         (Queue_refresh.For_testing.attempt_remembered
            ~base_path:config.base_path
            ~keeper_name:official_name
            ~trace_id:
              (Keeper_id.Trace_id.to_string official_meta.runtime.trace_id)
            ~meta:official_meta
            ~sources_changed:false
            ~trigger:Librarian_runtime.Queue_changed);
       Alcotest.(check (list (pair string string)))
         "official client emits one durable wake as well"
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

(* A purge of a Keeper whose lane never ran has nothing to wait for, returns
   at once, and creates no entry for a Keeper that is being deleted. *)
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

(* The Librarian setting is live while lane work is asynchronous. The
   post-turn entrypoint must reject OFF/INVALID before submission, then fence
   an already queued ON unit again before snapshot I/O when the setting changes
   while it waits behind an in-flight unit. *)
let test_post_turn_librarian_live_config_boundaries () =
  Lane.For_testing.reset ();
  let root = temp_dir "test-post-turn-librarian-gate-" in
  let env_key = Env_config.KeeperMemoryOs.librarian_env_key in
  let previous_env = Sys.getenv_opt env_key in
  Fun.protect
    ~finally:(fun () ->
      (match previous_env with
       | Some value -> Unix.putenv env_key value
       | None -> Unix.putenv env_key "");
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
      let failure_metric =
        Keeper_metrics.(to_string MemoryOsLibrarianFailures)
      in
      let failures_before =
        Masc.Otel_metric_store.metric_total failure_metric |> int_of_float
      in
      let cadence_entries_before =
        Librarian_runtime.cadence_counter_entries ()
      in
      let expect_no_admission ~value ~keeper_name ~turn =
        Unix.putenv env_key value;
        let meta = make_meta keeper_name in
        run_post_turn
          ~checkpoint_owner:Runtime_execution.Official_client
          ~config
          ~meta
          ~turn;
        match
          Lane.For_testing.pending
            ~base_path:config.base_path
            ~keeper_name
        with
        | None -> ()
        | Some pending ->
          Alcotest.failf
            "config=%s created Librarian lane pending=%d"
            value
            pending
      in
      expect_no_admission ~value:"false" ~keeper_name:"gateoff" ~turn:1;
      expect_no_admission ~value:"invalid" ~keeper_name:"gateinvalid" ~turn:2;
      let expect_queued_fence ~poison_snapshot ~terminal_value ~keeper_name ~turn =
        Lane.For_testing.reset ();
        Eio.Switch.run @@ fun sw ->
        Masc_test_deps.init_eio_clock ~sw env;
        Lane.init ~sw;
        let meta = make_meta keeper_name in
        let keepers_dir =
          Config_dir_resolver.keepers_dir_for_base_path
            ~base_path:config.base_path
        in
        if poison_snapshot
        then (
          Fs_compat.mkdir_p keepers_dir;
          Unix.mkdir
            (Memory_current.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name)
            0o755);
        Unix.putenv env_key "true";
        let started, set_started = Eio.Promise.create () in
        let release, set_release = Eio.Promise.create () in
        let blocker =
          Lane.submit
            ~base_path:config.base_path
            ~keeper_name
            (fun () ->
               Eio.Promise.resolve set_started ();
               Eio.Promise.await release)
        in
        (match blocker with
         | Lane.Submitted -> ()
         | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
           Alcotest.fail "Librarian blocker was not submitted");
        Eio.Promise.await started;
        run_post_turn
          ~checkpoint_owner:Runtime_execution.Official_client
          ~config
          ~meta
          ~turn;
        Alcotest.(check (option int))
          "one running plus one queued Librarian unit"
          (Some 2)
          (Lane.For_testing.pending
             ~base_path:config.base_path
             ~keeper_name
);
        Unix.putenv env_key terminal_value;
        Eio.Promise.resolve set_release ()
      in
      expect_queued_fence
        ~poison_snapshot:true
        ~terminal_value:"false"
        ~keeper_name:"queuedoff"
        ~turn:3;
      expect_queued_fence
        ~poison_snapshot:false
        ~terminal_value:"invalid"
        ~keeper_name:"queuedinvalid"
        ~turn:4;
      Alcotest.(check int)
        "fenced work did not read invalid snapshots or emit failures"
        failures_before
        (Masc.Otel_metric_store.metric_total failure_metric |> int_of_float);
      Alcotest.(check int)
        "fenced work did not advance Librarian cadence"
        cadence_entries_before
        (Librarian_runtime.cadence_counter_entries ()))
;;

let with_remembered_post_turn keeper_name f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  let module Refresh = Masc.Keeper_librarian_queue_refresh in
  let root = temp_dir "test-librarian-pending-input-" in
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_context = Eio_context.snapshot_state () in
  Lane.For_testing.reset ();
  Eio_context.restore_state initial_eio_context;
  Fun.protect
    ~finally:(fun () ->
      Eio_context.restore_state previous_context;
      (match previous_fs with
       | None -> Fs_compat.clear_fs ()
       | Some fs -> Fs_compat.set_fs fs);
      Config_dir_resolver.reset ();
      Lane.For_testing.reset ();
      remove_tree root)
    (fun () ->
      Masc_test_deps.with_process_env "MASC_CONFIG_DIR" None @@ fun () ->
      Masc_test_deps.with_process_env
        Env_config.KeeperMemoryOs.librarian_env_key (Some "true") @@ fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Masc_test_deps.init_eio_clock env;
      (* A real runtime entry records Runtime_context_unavailable and returns
         normally. No provider call or fake Memory reader is needed. *)
      Alcotest.(check bool) "fixture has no provider network context" true
        (Option.is_none (Eio_context.get_net_opt ()));
      let config = Masc.Workspace.default_config root in
      ignore (Masc.Workspace.init config ~agent_name:None);
      Config_dir_resolver.reset ();
      let meta = make_meta keeper_name in
      let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
      let keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
      in
      (match Memory_current.replace ~keepers_dir ~keeper_id:keeper_name
          ~expected_revision:None ~now:200.
          ~source:{ kind = Memory_current.Explicit_write; trace_id }
          ~facts:[] () with
       | Ok _ -> ()
       | Error detail -> Alcotest.fail detail);
      let snapshot_path =
        Memory_current.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name
      in
      let valid_snapshot = Fs_compat.load_file snapshot_path in
      run_post_turn ~checkpoint_owner:Runtime_execution.Official_client ~config ~meta ~turn:1;
      let attempt () =
        Refresh.For_testing.attempt_remembered
             ~base_path:config.base_path ~keeper_name ~trace_id ~meta
             ~sources_changed:false ~trigger:Librarian_runtime.Queue_changed
      in
      let runtime_entries () =
        Memory_current.read_journal_tail ~keepers_dir ~keeper_id:keeper_name ~limit:10
        |> List.filter (function
          | Ok (Memory_current.Journal_failed
                  { kind = Memory_current.Runtime_context_unavailable; _ }) -> true
          | Ok _ -> false
          | Error detail -> Alcotest.fail detail)
        |> List.length
      in
      Alcotest.(check int) "no runtime entry during submission" 0 (runtime_entries ());
      f ~config ~meta ~keepers_dir ~snapshot_path ~valid_snapshot ~attempt ~runtime_entries)
;;

let test_snapshot_read_failure_keeps_remembered_turn_pending () =
  let keeper_name = "snapshot-read-retry" in
  with_remembered_post_turn keeper_name
    (fun ~config:_ ~meta:_ ~keepers_dir ~snapshot_path ~valid_snapshot ~attempt ~runtime_entries ->
      Fs_compat.save_file snapshot_path "{ invalid snapshot\n";
      Alcotest.(check bool) "actual snapshot decoder rejects the fixture" true
        (Result.is_error
           (Memory_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name));
      Alcotest.(check bool) "remembered input remains available" true (attempt ());
      Alcotest.(check int) "read failure did not enter runtime" 0 (runtime_entries ());
      Fs_compat.save_file snapshot_path valid_snapshot;
      Alcotest.(check bool) "remembered input remains available" true (attempt ());
      Alcotest.(check int) "unchanged external wake enters after repair" 1 (runtime_entries ());
      Alcotest.(check bool) "remembered input remains available" true (attempt ());
      Alcotest.(check int) "runtime normal return suppresses unchanged wake" 1 (runtime_entries ()))
;;

let test_live_config_refusal_keeps_remembered_turn_pending value () =
  with_remembered_post_turn ("config-retry-" ^ value)
    (fun ~config:_ ~meta:_ ~keepers_dir:_ ~snapshot_path:_ ~valid_snapshot:_ ~attempt ~runtime_entries ->
      Unix.putenv Env_config.KeeperMemoryOs.librarian_env_key value;
      Alcotest.(check bool) "remembered input remains available" true (attempt ());
      Alcotest.(check int) "live setting refused runtime entry" 0 (runtime_entries ());
      Unix.putenv Env_config.KeeperMemoryOs.librarian_env_key "true";
      Alcotest.(check bool) "remembered input remains available" true (attempt ());
      Alcotest.(check int) "unchanged external wake enters after enabling" 1 (runtime_entries ());
      Alcotest.(check bool) "remembered input remains available" true (attempt ());
      Alcotest.(check int) "entered callback is not duplicated" 1 (runtime_entries ()))
;;

let test_handoff_read_failure_keeps_official_input_pending () =
  let keeper_name = "handoff-snapshot-read-retry" in
  with_remembered_post_turn keeper_name
    (fun ~config ~meta ~keepers_dir ~snapshot_path ~valid_snapshot ~attempt ~runtime_entries ->
      Fs_compat.save_file snapshot_path "{ invalid snapshot\n";
      Alcotest.(check bool) "actual snapshot decoder rejects the handoff fixture" true
        (Result.is_error
           (Memory_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name));
      let wakes = ref [] in
      Fun.protect
        ~finally:(fun () -> Queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ()))
        (fun () ->
          Queue_signal.install (fun ~base_path ~keeper_name ->
            wakes := (base_path, keeper_name) :: !wakes);
          run_post_turn ~checkpoint_owner:Runtime_execution.Masc_agent_core
            ~config ~meta ~turn:2;
          Alcotest.(check (list (pair string string))) "handoff requests the existing queue wake"
            [config.base_path, keeper_name] (List.rev !wakes));
      Alcotest.(check bool) "first wake handles pending official input" true (attempt ());
      Alcotest.(check int) "decoder refusal does not enter runtime" 0 (runtime_entries ());
      Fs_compat.save_file snapshot_path valid_snapshot;
      Alcotest.(check bool) "unchanged wake retains official input after repair" true (attempt ());
      Alcotest.(check int) "repaired handoff enters runtime once" 1 (runtime_entries ());
      Alcotest.(check bool) "entered handoff retires official input" false (attempt ());
      Alcotest.(check int) "retired input is not replayed" 1 (runtime_entries ()))
;;

(* A queue signal may replace the pending post-turn closure even when source
   coverage is unchanged. The replacement must still attempt the remembered
   conversation, while repeated unchanged signals need no further attempt. *)
let test_queue_coalescing_preserves_completed_turn () =
  let module Refresh = Masc.Keeper_librarian_queue_refresh in
  Lane.For_testing.reset ();
  let keeper_name = "queue-completed-turn" in
  let trace_id = "queue-trace" in
  let seen = ref [] in
  let attempt trigger () =
    ignore (Refresh.For_testing.attempt_remembered ~base_path ~keeper_name
      ~trace_id ~meta:(make_meta keeper_name) ~sources_changed:false ~trigger)
  in
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    Lane.init ~sw;
    let started, set_started = Eio.Promise.create () in
    let release, set_release = Eio.Promise.create () in
    ignore (Lane.submit ~base_path ~keeper_name (fun () ->
      Eio.Promise.resolve set_started ();
      Eio.Promise.await release));
    Eio.Promise.await started;
    Refresh.remember_turn ~base_path ~keeper_name ~trace_id
      (fun ~meta:_ trigger -> seen := trigger :: !seen; Refresh.Entered);
    ignore (Lane.submit ~base_path ~keeper_name
      (attempt Librarian_runtime.Conversation_completed));
    let outcome = Lane.submit ~base_path ~keeper_name
      (attempt Librarian_runtime.Queue_changed) in
    (match outcome with
     | Lane.Coalesced -> ()
     | _ -> Alcotest.fail "queue signal did not replace pending post-turn work");
    Eio.Promise.resolve set_release ()));
  (match !seen with
   | [Librarian_runtime.Queue_changed] -> ()
   | _ -> Alcotest.fail "unchanged queue lost or duplicated remembered turn");
  attempt Librarian_runtime.Queue_changed ();
  Alcotest.(check int) "attempted unchanged evidence is not retried" 1 (List.length !seen)
;;

let test_remembered_turn_replacement_and_cancellation () =
  let module Refresh = Masc.Keeper_librarian_queue_refresh in
  let keeper_name = "queue-turn-replacement" in
  let trace_id = "trace-current" in
  let seen = ref [] in
  let remember = Refresh.remember_turn ~base_path ~keeper_name ~trace_id in
  let attempt ?(sources_changed = false) trace_id =
    Refresh.For_testing.attempt_remembered ~base_path ~keeper_name
      ~trace_id ~meta:(make_meta keeper_name) ~sources_changed ~trigger:Librarian_runtime.Queue_changed
  in
  remember (fun ~meta:_ _ ->
    seen := "old" :: !seen;
    remember (fun ~meta:_ _ -> seen := "new" :: !seen; Refresh.Entered);
    Refresh.Entered);
  ignore (attempt trace_id);
  ignore (attempt trace_id);
  Alcotest.(check (list string)) "new evidence stays pending during old attempt"
    ["new"; "old"] !seen;
  let cancel_once = ref true in
  remember (fun ~meta:_ _ ->
    if !cancel_once then (
      cancel_once := false;
      raise (Eio.Cancel.Cancelled Test_boom));
    seen := "resumed" :: !seen;
    Refresh.Entered);
  (try ignore (attempt trace_id); Alcotest.fail "expected cancellation"
   with Eio.Cancel.Cancelled _ -> ());
  Alcotest.(check bool) "old trace cannot run latest evidence" false
    (attempt "trace-obsolete");
  ignore (attempt trace_id);
  Alcotest.(check (list string)) "cancellation preserves pending evidence"
    ["resumed"; "new"; "old"] !seen;
  ignore (attempt trace_id);
  Alcotest.(check int) "normal return records only one attempt" 3 (List.length !seen);
  ignore (attempt ~sources_changed:true trace_id);
  Alcotest.(check int) "changed sources reuse completed-turn evidence" 4 (List.length !seen)
;;

let test_remembered_turn_uses_current_policy () =
  let module Refresh = Masc.Keeper_librarian_queue_refresh in
  let keeper_name = "queue-policy-change" in
  let trace_id = "same-trace" in
  let meta = make_meta keeper_name in
  let seen = ref [] in
  let completed_evidence = ["completed user message"; "completed tool result"] in
  Refresh.remember_turn ~base_path ~keeper_name ~trace_id
    (fun ~meta _ ->
      seen := (meta.Masc.Keeper_meta_contract.instructions,
               meta.current_task_id, completed_evidence) :: !seen;
      Refresh.Entered);
  let attempt meta =
    Refresh.For_testing.attempt_remembered ~base_path ~keeper_name ~trace_id
      ~meta ~sources_changed:false ~trigger:Librarian_runtime.Queue_changed
  in
  Alcotest.(check bool) "first evidence handled" true (attempt meta);
  let changed = {meta with instructions = "explain only; do not execute"} in
  Alcotest.(check bool) "same trace policy change handled" true (attempt changed);
  let task_id = Keeper_id.Task_id.of_string "task-42" |> Result.get_ok in
  let changed = {changed with current_task_id = Some task_id} in
  Alcotest.(check bool) "same trace task change handled" true (attempt changed);
  Alcotest.(check bool) "unchanged policy handled" true (attempt changed);
  Alcotest.(check int) "only policy changes repeat extraction" 3 (List.length !seen);
  match !seen with
  | (instructions, Some task, evidence) :: _ ->
    Alcotest.(check string) "current instructions" changed.instructions instructions;
    Alcotest.(check bool) "current task" true (Keeper_id.Task_id.equal task_id task);
    Alcotest.(check (list string)) "completed evidence survives policy refresh"
      completed_evidence evidence
  | _ -> Alcotest.fail "current policy was not delivered with completed evidence"
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

let () =
  Alcotest.run
    "keeper_memory_lane"
    [ ( "lane"
      , [ Alcotest.test_case
            "queue coalescing preserves completed-turn evidence"
            `Quick test_queue_coalescing_preserves_completed_turn
        ; Alcotest.test_case
            "current policy preserves remembered evidence"
            `Quick test_remembered_turn_uses_current_policy
        ; Alcotest.test_case
            "remembered turn replacement and cancellation"
            `Quick test_remembered_turn_replacement_and_cancellation
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
            "finished switch drops without leak"
            `Quick
            test_finished_switch_drops_without_leak
        ; Alcotest.test_case "snapshot read refusal preserves pending input" `Quick
            test_snapshot_read_failure_keeps_remembered_turn_pending
        ; Alcotest.test_case "disabled config preserves pending input" `Quick
            (test_live_config_refusal_keeps_remembered_turn_pending "false")
        ; Alcotest.test_case "invalid config preserves pending input" `Quick
            (test_live_config_refusal_keeps_remembered_turn_pending "invalid")
        ; Alcotest.test_case "handoff decoder refusal preserves official input" `Quick
            test_handoff_read_failure_keeps_official_input_pending
        ; Alcotest.test_case
            "post-turn Librarian live config boundaries"
            `Quick
            test_post_turn_librarian_live_config_boundaries
        ] )
    ]
;;
