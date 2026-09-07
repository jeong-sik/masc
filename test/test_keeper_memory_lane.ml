(** Tests for Keeper_memory_lane (RFC-0257).

    The lane detaches post-turn memory work from the keeper turn lane:
    serialized within a keeper, independent across keepers, bounded, and
    leak-safe on a raising unit. *)

module Lane = Masc.Keeper_memory_lane
module Keeper_lane = Masc.Keeper_lane
module Librarian_runtime = Masc.Keeper_librarian_runtime
module Memory_current = Masc.Keeper_memory_os_current
module Post_turn_memory = Masc.Keeper_agent_run_post_turn_memory

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

let run_post_turn ~config ~(meta : Masc.Keeper_meta_contract.keeper_meta) ~turn =
  Post_turn_memory.run
    ~config
    ~meta
    ~turn
    ~agent_core_turn_count:1
    ~tool_observations:[]
    ~librarian_messages:[]
    ~post_turn_t0:(Time_compat.now ())
    ~inference_telemetry:None
    ()
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
  | Lane.Rejected_draining ->
    Alcotest.fail "expected Ran_inline, got Rejected_draining"
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
  | Lane.Rejected_draining ->
    Alcotest.fail "expected Ran_inline, got Rejected_draining"
;;

(* The startup inline fallback is still behind the lifecycle fence. A failed
   launch closes Librarian admission before the long-lived executor switch is
   installed, so falling back to inline execution must not reopen it. *)
let test_inline_rejects_draining_lifecycle () =
  Lane.For_testing.reset ();
  let ran = ref false in
  (match
     Lane.drain_and_join_librarian
       ~base_path
       ~keeper_name:"inline-draining"
   with
   | Ok Lane.No_librarian_work -> ()
   | Ok Lane.Librarian_drained ->
     Alcotest.fail "empty inline drain reported completed work"
   | Error error -> Alcotest.fail (Lane.librarian_drain_error_to_string error));
  (match
     Lane.submit
       ~base_path
       ~keeper_name:"inline-draining"
       (fun () -> ran := true)
   with
   | Lane.Rejected_draining -> ()
   | Lane.Submitted | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
     Alcotest.fail "inline fallback bypassed the lifecycle fence");
  Alcotest.(check bool) "draining inline unit did not run" false !ran
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
          | Lane.Dropped -> Alcotest.fail "cancel test unexpectedly dropped"
          | Lane.Rejected_draining ->
            Alcotest.fail "cancel test unexpectedly crossed a drain boundary");
         (match latest with
          | Lane.Submitted -> ()
          | Lane.Coalesced -> Alcotest.fail "first latest unit unexpectedly coalesced"
          | Lane.Ran_inline -> Alcotest.fail "latest cancel unit unexpectedly ran inline"
          | Lane.Dropped -> Alcotest.fail "latest cancel unit unexpectedly dropped"
          | Lane.Rejected_draining ->
            Alcotest.fail "latest cancel unit unexpectedly crossed a drain boundary");
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

let test_keeper_shutdown_drains_and_joins_librarian () =
  Lane.For_testing.reset ();
  let cancelled = ref false in
  let current_completed = ref false in
  let latest_completed = ref false in
  let raced_after_drain_ran = ref false in
  let reopened_completed = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let submitted =
        Lane.submit
          ~base_path
          ~keeper_name:"shutdown-owner"
          (fun () ->
             Eio.Promise.resolve set_started ();
             try
               Eio.Promise.await release;
               current_completed := true
             with
             | Eio.Cancel.Cancelled _ as exn ->
               cancelled := true;
               raise exn)
      in
      (match submitted with
       | Lane.Submitted -> ()
       | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped
       | Lane.Rejected_draining ->
         Alcotest.fail "shutdown Librarian was not submitted");
      Eio.Promise.await started;
      (match
         Lane.submit
           ~base_path
           ~keeper_name:"shutdown-owner"
           (fun () -> latest_completed := true)
       with
       | Lane.Submitted -> ()
       | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped
       | Lane.Rejected_draining ->
         Alcotest.fail "latest Librarian unit was not submitted");
      let joined, set_joined = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve
          set_joined
          (Lane.drain_and_join_librarian
             ~base_path
             ~keeper_name:"shutdown-owner"));
      Eio.Fiber.yield ();
      (match
         Lane.submit
           ~base_path
           ~keeper_name:"shutdown-owner"
           (fun () -> raced_after_drain_ran := true)
       with
       | Lane.Rejected_draining -> ()
       | Lane.Submitted | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
         Alcotest.fail "post-drain submission crossed the lifecycle boundary");
      (match Lane.begin_librarian_lifecycle ~base_path ~keeper_name:"shutdown-owner" with
       | Error Lane.Librarian_drain_still_active -> ()
       | Ok () -> Alcotest.fail "new lifecycle opened while the prior drain was active");
      Alcotest.(check bool)
        "join waits for the accepted current unit"
        true
        (Option.is_none (Eio.Promise.peek joined));
      Alcotest.(check bool) "provider scope was not cancelled" false !cancelled;
      Eio.Promise.resolve set_release ();
      (match Eio.Promise.await joined with
       | Ok Lane.Librarian_drained -> ()
       | Ok Lane.No_librarian_work -> Alcotest.fail "shutdown missed active Librarian"
       | Error error -> Alcotest.fail (Lane.librarian_drain_error_to_string error));
      Alcotest.(check bool) "current unit completed" true !current_completed;
      Alcotest.(check bool) "accepted latest unit completed" true !latest_completed;
      Alcotest.(check bool)
        "racing post-drain unit did not run"
        false
        !raced_after_drain_ran;
      Alcotest.(check bool) "provider scope stayed uncancelled" false !cancelled;
      Alcotest.(check (option int))
        "terminal join drained all Librarian work"
        (Some 0)
        (Lane.For_testing.pending
           ~base_path
           ~keeper_name:"shutdown-owner");
      (match
         Lane.submit
           ~base_path
           ~keeper_name:"shutdown-owner"
           (fun () -> Alcotest.fail "closed lifecycle accepted later work")
       with
       | Lane.Rejected_draining -> ()
       | Lane.Submitted | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
         Alcotest.fail "terminal drain fence reopened without a new lifecycle");
      (match Lane.begin_librarian_lifecycle ~base_path ~keeper_name:"shutdown-owner" with
       | Ok () -> ()
       | Error error -> Alcotest.fail (Lane.lifecycle_open_error_to_string error));
      let reopened_done, set_reopened_done = Eio.Promise.create () in
      (match
         Lane.submit
           ~base_path
           ~keeper_name:"shutdown-owner"
           (fun () ->
              reopened_completed := true;
              Eio.Promise.resolve set_reopened_done ())
       with
       | Lane.Submitted -> ()
       | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped
       | Lane.Rejected_draining ->
         Alcotest.fail "new lifecycle could not submit Librarian work");
      Eio.Promise.await reopened_done;
      Alcotest.(check bool) "new lifecycle work completed" true !reopened_completed))
;;

let test_empty_drain_fences_late_submission () =
  Lane.For_testing.reset ();
  let late_ran = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      (match
         Lane.drain_and_join_librarian
           ~base_path
           ~keeper_name:"empty-drain-owner"
       with
       | Ok Lane.No_librarian_work -> ()
       | Ok Lane.Librarian_drained ->
         Alcotest.fail "empty drain reported completed work"
       | Error error ->
         Alcotest.fail (Lane.librarian_drain_error_to_string error));
      (match
         Lane.submit
           ~base_path
           ~keeper_name:"empty-drain-owner"
           (fun () -> late_ran := true)
       with
       | Lane.Rejected_draining -> ()
       | Lane.Submitted | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped ->
         Alcotest.fail "empty drain left no lifecycle fence");
      Alcotest.(check bool) "late empty-drain unit did not run" false !late_ran))
;;

let test_drain_reports_parent_cancellation () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun _root_sw ->
      (try
         Eio.Switch.run (fun executor_sw ->
           Lane.init ~sw:executor_sw;
           let started, set_started = Eio.Promise.create () in
           let never, _set_never = Eio.Promise.create () in
           (match
              Lane.submit
                ~base_path
                ~keeper_name:"cancelled-drain-owner"
                (fun () ->
                   Eio.Promise.resolve set_started ();
                   Eio.Promise.await never)
            with
            | Lane.Submitted -> ()
            | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped
           | Lane.Rejected_draining ->
              Alcotest.fail "cancellation fixture was not submitted");
           Eio.Promise.await started;
           Eio.Switch.fail executor_sw Cancel_lane_test)
       with
       | Cancel_lane_test -> ());
      (* The owner and its cleanup have already finished. Shutdown must still
         observe that exact terminal receipt instead of treating the detached
         entry as ownerless success. *)
      match
        Lane.drain_and_join_librarian
          ~base_path
          ~keeper_name:"cancelled-drain-owner"
      with
      | Error (Lane.Librarian_interrupted (Keeper_lane.Cancelled_by_parent _)) -> ()
      | Error error ->
        Alcotest.failf
          "unexpected typed drain error: %s"
          (Lane.librarian_drain_error_to_string error)
      | Ok Lane.No_librarian_work ->
        Alcotest.fail "cancelled active drain was reported as no work"
      | Ok Lane.Librarian_drained ->
        Alcotest.fail "parent-cancelled drain was reported as completed"))
;;

let test_abort_cancels_without_joining_provider_work () =
  Lane.For_testing.reset ();
  let cancelled = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let never, _set_never = Eio.Promise.create () in
      (match
         Lane.submit
           ~base_path
           ~keeper_name:"crashed-owner"
           (fun () ->
              Eio.Promise.resolve set_started ();
              try Eio.Promise.await never with
              | Eio.Cancel.Cancelled _ as exn ->
                cancelled := true;
                raise exn)
       with
       | Lane.Submitted -> ()
       | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped
       | Lane.Rejected_draining ->
         Alcotest.fail "crash-abort Librarian was not submitted");
      Eio.Promise.await started;
      (match Lane.abort_librarian ~base_path ~keeper_name:"crashed-owner" with
       | Ok Lane.Librarian_abort_requested
       | Ok Lane.Librarian_abort_already_in_progress -> ()
       | Ok Lane.Librarian_abort_idle ->
         Alcotest.fail "active crash-abort Librarian was reported idle"
       | Ok (Lane.Librarian_abort_already_exited _) ->
         Alcotest.fail "active crash-abort Librarian had already exited"
       | Ok (Lane.Librarian_abort_committed_with_failure exn) ->
         Alcotest.failf
           "crash-abort cancellation callback failed: %s"
           (Printexc.to_string exn)
       | Error error -> Alcotest.fail (Lane.librarian_abort_error_to_string error));
      match Lane.drain_and_join_librarian ~base_path ~keeper_name:"crashed-owner" with
      | Error (Lane.Librarian_interrupted Keeper_lane.Shutdown_requested) ->
        Alcotest.(check bool) "provider work was cancelled" true !cancelled
      | Error error ->
        Alcotest.failf
          "unexpected crash-abort receipt: %s"
          (Lane.librarian_drain_error_to_string error)
      | Ok Lane.No_librarian_work ->
        Alcotest.fail "crash-abort lost the exact owner receipt"
      | Ok Lane.Librarian_drained ->
        Alcotest.fail "cancelled crash-abort work was reported drained"))
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
   | Lane.Ran_inline -> Alcotest.fail "expected Dropped, got Ran_inline"
   | Lane.Rejected_draining ->
     Alcotest.fail "expected Dropped, got Rejected_draining");
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 ->
    (match Lane.drain_and_join_librarian ~base_path ~keeper_name:"k1" with
     | Error (Lane.Librarian_interrupted (Keeper_lane.Failed _)) -> ()
     | Error error ->
       Alcotest.failf
         "finished-switch drain returned an unexpected error: %s"
         (Lane.librarian_drain_error_to_string error)
     | Ok Lane.No_librarian_work ->
       Alcotest.fail "finished-switch drop lost its terminal owner receipt"
     | Ok Lane.Librarian_drained ->
       Alcotest.fail "finished-switch drop was reported as completed");
    (match Lane.begin_librarian_lifecycle ~base_path ~keeper_name:"k1" with
     | Ok () -> ()
     | Error error ->
       Alcotest.fail
         ("finished-switch receipt prevented lifecycle reopen: "
          ^ Lane.lifecycle_open_error_to_string error));
    (match Lane.drain_and_join_librarian ~base_path ~keeper_name:"k1" with
     | Ok Lane.No_librarian_work -> ()
     | Ok Lane.Librarian_drained ->
       Alcotest.fail "reopened empty lifecycle retained stale completed work"
     | Error error ->
       Alcotest.failf
         "reopened lifecycle retained stale owner receipt: %s"
         (Lane.librarian_drain_error_to_string error))
  | Some n -> Alcotest.failf "pending leaked after finished switch submit: %d" n
  | None -> Alcotest.fail "keeper entry missing after finished switch submit"
;;

let test_accepting_reopen_clears_exited_owner_receipt () =
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
  (match Lane.submit ~base_path ~keeper_name:"accepting-reopen" (fun () -> raise Test_boom) with
   | Lane.Dropped -> ()
   | Lane.Submitted | Lane.Coalesced | Lane.Ran_inline
   | Lane.Rejected_draining ->
     Alcotest.fail "finished executor did not drop the Librarian unit");
  (* Reopen before a drain can change [Accepting] to [Draining]. This exact
     ordering used to carry the prior failed receipt into the new lifecycle. *)
  (match
     Lane.begin_librarian_lifecycle
       ~base_path
       ~keeper_name:"accepting-reopen"
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Lane.lifecycle_open_error_to_string error));
  match
    Lane.drain_and_join_librarian
      ~base_path
      ~keeper_name:"accepting-reopen"
  with
  | Ok Lane.No_librarian_work -> ()
  | Ok Lane.Librarian_drained ->
    Alcotest.fail "reopened lifecycle inherited completed prior work"
  | Error error ->
    Alcotest.failf
      "reopened accepting lifecycle inherited stale owner receipt: %s"
      (Lane.librarian_drain_error_to_string error)
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
        run_post_turn ~config ~meta ~turn;
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
         | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped
         | Lane.Rejected_draining ->
           Alcotest.fail "Librarian blocker was not submitted");
        Eio.Promise.await started;
        run_post_turn ~config ~meta ~turn;
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

(* A drain that exceeds its timeout must report [Librarian_drain_timed_out]
   instead of blocking keeper termination forever inside [Eio.Cancel.protect],
   where no outer cancellation can interrupt the join (issue #33576). *)
let test_drain_reports_timeout_when_owner_never_exits () =
  Lane.For_testing.reset ();
  let result = ref None in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        @@ fun () ->
      Lane.init ~sw;
      Lane.For_testing.set_drain_timeout_sec 0.3;
      let started, set_started = Eio.Promise.create () in
      (* Keep the resolver: after the drain reports its timeout we release the
         parked unit so [Eio.Switch.run] is not blocked by it at teardown. *)
      let park, release_park = Eio.Promise.create () in
      (match
         Lane.submit ~base_path ~keeper_name:"hung-owner" (fun () ->
             Eio.Promise.resolve set_started ();
             Eio.Promise.await park)
       with
       | Lane.Submitted -> ()
       | Lane.Coalesced | Lane.Ran_inline | Lane.Dropped
       | Lane.Rejected_draining ->
         Alcotest.fail "hung-owner unit was not submitted");
      Eio.Promise.await started;
      (* Mirror finish_lifecycle: the join runs inside Cancel.protect, so an
         outer [with_timeout_exn] cannot cancel it (issue #33576). A regression
         here therefore hangs until the test runner's own timeout kills it —
         that is the failure mode this cap exists to remove. *)
      Eio.Cancel.protect (fun () ->
          result :=
            Some
              (Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
                   Lane.drain_and_join_librarian
                     ~base_path
                     ~keeper_name:"hung-owner")));
      Eio.Promise.resolve release_park ()));
  match !result with
  | None -> Alcotest.fail "drain never returned"
  | Some (Error (Lane.Librarian_drain_timed_out seconds)) ->
    Alcotest.(check (float 1e-6)) "cap elapsed" 0.3 seconds
  | Some (Error error) ->
    Alcotest.failf
      "expected drain timeout, got: %s"
      (Lane.librarian_drain_error_to_string error)
  | Some (Ok Lane.No_librarian_work) ->
    Alcotest.fail "drain lost the hung owner entirely"
  | Some (Ok Lane.Librarian_drained) ->
    Alcotest.fail "hung owner was reported as drained"
;;

let () =
  Alcotest.run
    "keeper_memory_lane"
    [ ( "lane"
      , [ Alcotest.test_case
            "inline when uninitialized"
            `Quick
            test_inline_when_uninitialized
        ; Alcotest.test_case
            "inline contains raise"
            `Quick
            test_inline_contains_raise
        ; Alcotest.test_case
            "inline rejects draining lifecycle"
            `Quick
            test_inline_rejects_draining_lifecycle
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
            "Keeper shutdown drains and joins Librarian"
            `Quick
            test_keeper_shutdown_drains_and_joins_librarian
        ; Alcotest.test_case
            "drain reports parent cancellation"
            `Quick
            test_drain_reports_parent_cancellation
        ; Alcotest.test_case
            "drain reports timeout when owner never exits"
            `Quick
            test_drain_reports_timeout_when_owner_never_exits
        ; Alcotest.test_case
            "crash abort cancels without joining provider work"
            `Quick
            test_abort_cancels_without_joining_provider_work
        ; Alcotest.test_case
            "empty drain fences late submission"
            `Quick
            test_empty_drain_fences_late_submission
        ; Alcotest.test_case
            "finished switch drops without leak"
            `Quick
            test_finished_switch_drops_without_leak
        ; Alcotest.test_case
            "accepting reopen clears exited owner receipt"
            `Quick
            test_accepting_reopen_clears_exited_owner_receipt
        ; Alcotest.test_case
            "post-turn Librarian live config boundaries"
            `Quick
            test_post_turn_librarian_live_config_boundaries
        ] )
    ]
;;
