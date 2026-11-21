(** Tests for Keeper_memory_lane.

    The lane detaches post-turn memory work from the keeper turn lane:
    serialized within a keeper, independent across keepers, bounded, and
    leak-safe on a raising unit. *)

module Lane = Masc.Keeper_memory_lane
module Keeper_lane = Masc.Keeper_lane
module Post_turn_memory = Masc.Keeper_agent_run_post_turn_memory
module Signal = Masc.Keeper_working_context_signal

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

let test_either_checkpoint_owner_signals_the_working_context_pass () =
  Lane.For_testing.reset ();
  let root = temp_dir "test-post-turn-owner-" in
  let env_key = Env_config.KeeperMemoryOs.librarian_env_key in
  let previous_env = Sys.getenv_opt env_key in
  Fun.protect
    ~finally:(fun () ->
      (match previous_env with
       | Some value -> Unix.putenv env_key value
       | None -> Unix.putenv env_key "");
      Signal.install (fun ~base_path:_ ~keeper_name:_ -> ());
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
       Signal.install (fun ~base_path ~keeper_name ->
         wakes := (base_path, keeper_name) :: !wakes);
       let core_name = "agent-core-owner" in
       let core_meta = make_meta core_name in
       run_post_turn
         ~checkpoint_owner:Runtime_execution.Masc_agent_core
         ~config
         ~meta:core_meta
         ~turn:1;
       Alcotest.(check (list (pair string string)))
         "an Agent Core turn signals the working-context pass once"
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
         "an official-client turn signals it once as well"
         [ config.base_path, core_name; config.base_path, official_name ]
         (List.rev !wakes);
       Unix.putenv env_key "false";
       run_post_turn
         ~checkpoint_owner:Runtime_execution.Official_client
         ~config
         ~meta:official_meta
         ~turn:2;
       Alcotest.(check (list (pair string string)))
         "a disabled Librarian signals nothing"
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

(* [has_waiting] is true exactly while a unit waits behind the
   running one. Reading it registers no lane entry, and the waiting unit,
   once it runs, sees nothing behind itself. *)
let test_has_waiting_reads_the_latest_slot () =
  Lane.For_testing.reset ();
  let keeper_name = "k-waiting" in
  Alcotest.(check bool) "no entry: nothing waits" false
    (Lane.has_waiting ~base_path ~keeper_name);
  Alcotest.(check (option int)) "reading registered no entry" None
    (Lane.For_testing.pending ~base_path ~keeper_name);
  let seen_by_second = ref None in
  let pending_by_second = ref None in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let (_ : Lane.outcome) =
        Lane.submit ~base_path ~keeper_name (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release)
      in
      Eio.Promise.await started;
      Alcotest.(check bool) "a running unit alone: nothing waits" false
        (Lane.has_waiting ~base_path ~keeper_name);
      Alcotest.(check (option int)) "the current unit is pending" (Some 1)
        (Lane.For_testing.pending ~base_path ~keeper_name);
      let (_ : Lane.outcome) =
        Lane.submit ~base_path ~keeper_name (fun () ->
          seen_by_second := Some (Lane.has_waiting ~base_path ~keeper_name);
          pending_by_second := Lane.For_testing.pending ~base_path ~keeper_name)
      in
      Alcotest.(check bool) "a unit behind the running one waits" true
        (Lane.has_waiting ~base_path ~keeper_name);
      Alcotest.(check (option int)) "current and latest units are pending" (Some 2)
        (Lane.For_testing.pending ~base_path ~keeper_name);
      Eio.Promise.resolve set_release ();
      Lane.For_testing.await_idle ~base_path ~keeper_name;
      Alcotest.(check bool) "the lane drained: nothing waits" false
        (Lane.has_waiting ~base_path ~keeper_name);
      Alcotest.(check (option int)) "the lane drained: none pending" (Some 0)
        (Lane.For_testing.pending ~base_path ~keeper_name)));
  Alcotest.(check (option bool)) "the waiting unit ran and saw nothing behind it"
    (Some false) !seen_by_second;
  Alcotest.(check (option int)) "the promoted latest is the current unit"
    (Some 1) !pending_by_second
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
let test_external_effect_without_executor_is_cancelled_and_joined () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let started,signal=Eio.Promise.create () and finished,finish=Eio.Promise.create () in
    let never,_=Eio.Promise.create () in
    let cleaned=ref false in
    Eio.Fiber.fork ~sw (fun () ->
      let result=Lane.with_external_effect ~base_path ~keeper_name:"external-only" (fun () ->
        Fun.protect ~finally:(fun () -> cleaned:=true) (fun () ->
          Eio.Promise.resolve signal ();Eio.Promise.await never)) in
      Eio.Promise.resolve finish result);
    Eio.Promise.await started;
    Alcotest.(check int) "executor initialization is unnecessary" 1
      (Lane.For_testing.external_active ~base_path ~keeper_name:"external-only");
    (match Lane.with_librarian_purge ~base_path ~keeper_name:"external-only" (fun () ->
      Alcotest.(check bool) "actual inline scope cleaned before deletion" true !cleaned;
      Alcotest.(check int) "no external scope survives the join" 0
        (Lane.For_testing.external_active ~base_path ~keeper_name:"external-only");
      match Lane.with_external_effect ~base_path ~keeper_name:"external-only" (fun () -> Alcotest.fail "purge admitted new work") with
      | Error Lane.External_purge_in_progress -> ()
      | Ok _ | Error External_cancelled_by_purge -> Alcotest.fail "purge did not exclude registration") with
     | Ok () -> () | Error error -> Alcotest.fail (Lane.purge_cancel_error_to_string error));
    (match Eio.Promise.await finished with
     | Error Lane.External_cancelled_by_purge -> ()
     | Ok _ | Error External_purge_in_progress -> Alcotest.fail "exact purge cancellation was not retained");
    Alcotest.(check bool) "successful purge releases the fence" true
      (Lane.with_external_effect ~base_path ~keeper_name:"external-only" (fun () -> 42)=Ok 42)))
;;

let test_purge_signals_external_before_joining_drain () =
  Lane.For_testing.reset ();
  Eio_main.run (fun env -> Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let external_started,external_signal=Eio.Promise.create () in
      let external_exited,external_exit=Eio.Promise.create () in
      let unit_started,unit_signal=Eio.Promise.create () in
      let never,_=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        ignore (Lane.with_external_effect ~base_path ~keeper_name:"joined" (fun () ->
          Fun.protect ~finally:(fun () -> Eio.Promise.resolve external_exit ()) (fun () ->
            Eio.Promise.resolve external_signal ();Eio.Promise.await never))));
      Eio.Promise.await external_started;
      ignore (Lane.submit ~base_path ~keeper_name:"joined" (fun () ->
        Eio.Promise.resolve unit_signal ();
        Eio.Cancel.protect (fun () -> Eio.Promise.await external_exited)));
      Eio.Promise.await unit_started;
      (match Lane.with_librarian_purge ~base_path ~keeper_name:"joined" (fun () ->
        Alcotest.(check int) "drain and external scope are both settled" 0
          (Lane.For_testing.external_active ~base_path ~keeper_name:"joined")) with
       | Ok () -> () | Error error -> Alcotest.fail (Lane.purge_cancel_error_to_string error)))))
;;

let test_external_purge_wrong_domain_is_fail_closed () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let started,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
    let done_,finish=Eio.Promise.create () and deleted=ref false in
    Eio.Fiber.fork ~sw (fun () ->
      let result=Lane.with_external_effect ~base_path ~keeper_name:"domain-owned" (fun () ->
        Eio.Promise.resolve signal ();Eio.Promise.await release) in
      Eio.Promise.resolve finish result);
    Eio.Promise.await started;
    let foreign=Domain.spawn (fun () -> Eio_main.run (fun _ ->
      Lane.with_librarian_purge ~base_path ~keeper_name:"domain-owned" (fun () -> deleted:=true))) in
    (match Domain.join foreign with
     | Error Lane.Purge_cancel_wrong_domain -> ()
     | Ok () | Error (Purge_already_in_progress | Purge_cancel_not_committed _) -> Alcotest.fail "foreign cancellation did not fail closed");
    Alcotest.(check bool) "wrong domain cannot enter deletion" false !deleted;
    Alcotest.(check int) "the original domain still owns its effect" 1
      (Lane.For_testing.external_active ~base_path ~keeper_name:"domain-owned");
    Eio.Promise.resolve unblock ();
    match Eio.Promise.await done_ with
    | Ok () -> () | Error error -> Alcotest.fail (Lane.external_effect_error_to_string error)))
;;

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

let () =
  Alcotest.run
    "keeper_memory_lane"
    [ ( "lane"
      , [ Alcotest.test_case
            "either checkpoint owner signals the working-context pass"
            `Quick
            test_either_checkpoint_owner_signals_the_working_context_pass
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
        ; Alcotest.test_case "has_waiting reads the latest slot" `Quick
            test_has_waiting_reads_the_latest_slot
        ; Alcotest.test_case "releases on raise" `Quick test_releases_on_raise
        ; Alcotest.test_case "releases on cancel" `Quick test_releases_on_cancel
        ; Alcotest.test_case "external inline scope is cancelled without executor initialization" `Quick
            test_external_effect_without_executor_is_cancelled_and_joined
        ; Alcotest.test_case "purge signals external work before joining a waiting drain" `Quick
            test_purge_signals_external_before_joining_drain
        ; Alcotest.test_case "external cancellation from the wrong domain fails closed" `Quick
            test_external_purge_wrong_domain_is_fail_closed
        ; Alcotest.test_case
            "purge cancels the running unit and leaves no fence"
            `Quick
            test_purge_cancels_running_unit_and_leaves_no_fence
        ; Alcotest.test_case
            "purge bracket releases on failure and cancellation"
            `Quick test_purge_bracket_releases_on_failure_and_cancellation
        ; Alcotest.test_case
            "purge with nothing running returns at once"
            `Quick
            test_purge_with_nothing_running_returns_at_once
        ; Alcotest.test_case
            "finished switch drops without leak"
            `Quick
            test_finished_switch_drops_without_leak
        ] )
    ]
;;
