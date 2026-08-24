open Alcotest

module Chat = Masc_tui_keeper_chat_projection
module Recovery = Masc_tui_keeper_chat_recovery

let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) "--hold-dispatch-lock"
  then begin
    let fd =
      Unix.openfile Sys.argv.(2) [ Unix.O_CREAT; Unix.O_WRONLY ] 0o600
    in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        output_char stdout 'R';
        flush stdout;
        ignore (input_char stdin));
    exit 0
  end

let request () = Chat.create_request ~keeper_name:"keeper.one" ~message:"hello"

let with_base name f =
  let base_path = Filename.temp_dir ("tui-chat-recovery-" ^ name) "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    f base_path)

let expect_fsync label = function
  | Ok Recovery.Fsync_completed -> ()
  | Ok (Recovery.Visible_sync_unconfirmed detail) ->
      failf "%s unexpectedly left parent sync unconfirmed: %s" label detail
  | Ok (Recovery.Durable_write_cancelled detail) ->
      failf "%s unexpectedly cancelled after durable write: %s" label detail
  | Ok Recovery.Dispatching_already ->
      failf "%s unexpectedly found a dispatch claim" label
  | Ok Recovery.Accepted_already -> failf "%s unexpectedly found acceptance" label
  | Error detail -> failf "%s failed: %s" label detail

let expect_phase label expected = function
  | Ok (Some pending) ->
      check bool label true (pending.Recovery.phase = expected);
      pending.request
  | Ok None -> failf "%s disappeared" label
  | Error detail -> fail detail

let staged_error ~path ~stage exception_ =
  let failure : Fs_compat.atomic_replace_failure =
    { path
    ; stage
    ; exception_
    ; backtrace = Printexc.get_callstack 16
    }
  in
  Error failure

let visible_after_rename_writer ?(exception_ = Failure "parent sync failed") path
    content =
  Fs_compat.save_file path content;
  Unix.chmod path 0o600;
  staged_error ~path ~stage:Fs_compat.After_rename exception_

let test_round_trip_accept_and_clear () =
  with_base "roundtrip" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "persist";
  let path = Recovery.recovery_path ~base_path in
  check int "private prepared mode" 0o600 ((Unix.stat path).st_perm land 0o777);
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "prepared recovery request" Recovery.Prepared
  in
  check bool "exact prepared request" true
    (Chat.same_request_identity expected observed);
  Recovery.mark_accepted ~base_path expected |> expect_fsync "mark accepted";
  check int "private accepted mode" 0o600 ((Unix.stat path).st_perm land 0o777);
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "accepted recovery request" Recovery.Accepted
  in
  check bool "exact accepted request" true
    (Chat.same_request_identity expected observed);
  check (result unit string) "clear" (Ok ())
    (Recovery.clear_pending ~base_path expected);
  check bool "removed" false (Fs_compat.file_exists path)

let test_conflict_fails_closed () =
  with_base "conflict" @@ fun base_path ->
  let first = request () in
  let second = request () in
  Recovery.persist_pending ~base_path first |> expect_fsync "first persist";
  (match Recovery.persist_pending ~base_path second with
   | Error _ -> ()
   | Ok _ -> fail "a second request replaced the active recovery fence");
  (match Recovery.clear_pending ~base_path second with
   | Error _ -> ()
   | Ok () -> fail "a different request cleared the active recovery fence");
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "conflicting recovery request" Recovery.Prepared
  in
  check bool "first fence retained" true
    (Chat.same_request_identity first observed)

let test_malformed_fails_closed () =
  with_base "malformed" @@ fun base_path ->
  let path = Recovery.recovery_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path
    {|{"schema":"masc.tui_keeper_chat_recovery.v3","phase":"prepared","request_id":"bad","keeper_name":"keeper.one","message":"hello","extra":true}|};
  match Recovery.load_pending ~base_path with
  | Error _ -> ()
  | Ok _ -> fail "malformed recovery record was accepted"

let test_v2_record_is_hard_cut () =
  with_base "v2-hard-cut" @@ fun base_path ->
  let expected = request () in
  let path = Recovery.recovery_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path
    (Printf.sprintf
       {|{"schema":"masc.tui_keeper_chat_recovery.v2","phase":"prepared","request_id":%S,"keeper_name":%S,"message":%S}|}
       expected.request_id expected.keeper_name expected.message);
  match Recovery.load_pending ~base_path with
  | Error detail ->
      check bool "schema rejection" true
        (String.equal detail "Keeper chat recovery schema is unsupported")
  | Ok _ -> fail "v2 recovery record bypassed the dispatching hard cut"

let test_bounded_poll_budget () =
  check int "positive budget" 40 Recovery.max_reconciliation_polls;
  check bool "decrement" true
    (Recovery.next_reconciliation_poll ~remaining:2 = `Poll 1);
  check bool "stop at last attempt" true
    (Recovery.next_reconciliation_poll ~remaining:1 = `Stop);
  check bool "stop exhausted" true
    (Recovery.next_reconciliation_poll ~remaining:0 = `Stop)

let test_after_rename_retains_prepared_without_dispatch () =
  with_base "after-rename" @@ fun base_path ->
  let expected = request () in
  (match
     Recovery.For_testing.persist_pending_with_writer
       ~save_file_atomic_strict_staged:visible_after_rename_writer
       ~base_path expected
   with
   | Ok (Recovery.Visible_sync_unconfirmed detail) ->
       check bool "failure detail retained" true (String.length detail > 0)
   | Ok Recovery.Fsync_completed -> fail "after-rename failure claimed fsync"
   | Ok (Recovery.Durable_write_cancelled _) ->
       fail "ordinary after-rename failure became cancellation"
   | Ok Recovery.Dispatching_already -> fail "prepared write found dispatching"
   | Ok Recovery.Accepted_already -> fail "prepared write observed acceptance"
   | Error detail -> failf "visible prepared fence was rejected: %s" detail);
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "visible prepared request" Recovery.Prepared
  in
  check bool "visible exact request" true
    (Chat.same_request_identity expected observed);
  Recovery.persist_pending ~base_path expected |> expect_fsync "same-ID refsync"

let test_before_rename_failure_leaves_no_fence () =
  with_base "before-rename" @@ fun base_path ->
  let expected = request () in
  let writer path _content =
    staged_error ~path ~stage:Fs_compat.Before_rename (Failure "write failed")
  in
  (match
     Recovery.For_testing.persist_pending_with_writer
       ~save_file_atomic_strict_staged:writer ~base_path expected
   with
   | Error _ -> ()
   | Ok _ -> fail "before-rename failure was accepted");
  check bool "no fence installed" false
    (Fs_compat.file_exists (Recovery.recovery_path ~base_path))

let test_before_rename_cancellation_stays_loud () =
  with_base "before-cancel" @@ fun base_path ->
  let expected = request () in
  let writer path _content =
    staged_error ~path ~stage:Fs_compat.Before_rename
      (Eio.Cancel.Cancelled (Failure "cancelled before rename"))
  in
  let raised =
    try
      ignore
        (Recovery.For_testing.persist_pending_with_writer
           ~save_file_atomic_strict_staged:writer ~base_path expected);
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  check bool "cancellation re-raised" true raised;
  check bool "cancelled write installed no fence" false
    (Fs_compat.file_exists (Recovery.recovery_path ~base_path))

let test_after_rename_cancellation_is_visible_unconfirmed () =
  with_base "after-cancel" @@ fun base_path ->
  let expected = request () in
  let writer =
    visible_after_rename_writer
      ~exception_:(Eio.Cancel.Cancelled (Failure "cancelled after rename"))
  in
  (match
     Recovery.For_testing.persist_pending_with_writer
       ~save_file_atomic_strict_staged:writer ~base_path expected
   with
   | Ok (Recovery.Visible_sync_unconfirmed _) -> ()
   | Ok Recovery.Fsync_completed -> fail "after-rename cancellation claimed fsync"
   | Ok (Recovery.Durable_write_cancelled _) ->
       fail "raw staged cancellation claimed a durable commit"
   | Ok Recovery.Dispatching_already ->
       fail "prepared cancellation found dispatching"
   | Ok Recovery.Accepted_already -> fail "prepared cancellation observed acceptance"
   | Error detail -> failf "after-rename cancellation lost visibility: %s" detail);
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "cancelled visible request" Recovery.Prepared
  in
  check bool "cancelled exact request" true
    (Chat.same_request_identity expected observed)

let test_durable_adapter_records_postcommit_cancellation () =
  with_base "durable-adapter-postcommit-cancel" @@ fun base_path ->
  let path = Recovery.recovery_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  let writer ~on_durable_commit ~ownership_root:_ _path _content =
    on_durable_commit ();
    raise (Eio.Cancel.Cancelled (Failure "cancelled after durable commit"))
  in
  match
    Recovery.For_testing.save_file_durable_staged_with
      ~save_bytes_durable_atomic_observed:writer ~base_path path "exact bytes\n"
  with
  | Error { Fs_compat.stage = Fs_compat.After_rename; _ } -> ()
  | Error { stage = Fs_compat.Before_rename; _ } ->
      fail "durable observer lost its postcommit boundary"
  | Ok () -> fail "postcommit cancellation authorized dispatch"

let test_durable_adapter_reraises_prewrite_cancellation () =
  with_base "durable-adapter-prewrite-cancel" @@ fun base_path ->
  let path = Recovery.recovery_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  let writer ~on_durable_commit:_ ~ownership_root:_ _path _content =
    raise (Eio.Cancel.Cancelled (Failure "cancelled before durable rename"))
  in
  let raised =
    try
      ignore
        (Recovery.For_testing.save_file_durable_staged_with
           ~save_bytes_durable_atomic_observed:writer ~base_path path
           "exact bytes\n");
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  check bool "prewrite cancellation re-raised" true raised

let test_durable_adapter_requires_commit_observation () =
  with_base "durable-adapter-existing-cancel" @@ fun base_path ->
  let path = Recovery.recovery_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path "exact bytes\n";
  let writer ~on_durable_commit:_ ~ownership_root:_ _path _content =
    raise (Eio.Cancel.Cancelled (Failure "cancelled before replacement"))
  in
  let raised =
    try
      ignore
        (Recovery.For_testing.save_file_durable_staged_with
           ~save_bytes_durable_atomic_observed:writer ~base_path path
           "exact bytes\n");
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  check bool "existing bytes do not imply a new durable commit" true raised

let test_accepted_after_rename_is_typed () =
  with_base "accepted-after-rename" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  (match
     Recovery.For_testing.mark_accepted_with_writer
       ~save_file_atomic_strict_staged:visible_after_rename_writer
       ~base_path expected
   with
   | Ok (Recovery.Visible_sync_unconfirmed _) -> ()
   | Ok Recovery.Fsync_completed -> fail "after-rename acceptance claimed fsync"
   | Ok (Recovery.Durable_write_cancelled _) ->
       fail "ordinary acceptance failure became cancellation"
   | Ok Recovery.Dispatching_already ->
       fail "acceptance update reported dispatching"
   | Ok Recovery.Accepted_already -> fail "acceptance update skipped its write"
   | Error detail -> failf "accepted phase was not retained: %s" detail);
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "visible accepted request" Recovery.Accepted
  in
  check bool "accepted exact request" true
    (Chat.same_request_identity expected observed)

let test_mark_accepted_recreates_missing_fence () =
  with_base "accepted-missing" @@ fun base_path ->
  let expected = request () in
  Recovery.mark_accepted ~base_path expected
  |> expect_fsync "recreate accepted fence";
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "recreated accepted request" Recovery.Accepted
  in
  check bool "recreated exact request" true
    (Chat.same_request_identity expected observed)

let test_persist_observes_cross_process_acceptance () =
  with_base "accepted-race" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  Recovery.mark_accepted ~base_path expected |> expect_fsync "accept";
  match Recovery.persist_pending ~base_path expected with
  | Ok Recovery.Accepted_already -> ()
  | Ok Recovery.Fsync_completed -> fail "accepted fence granted another POST"
  | Ok (Recovery.Durable_write_cancelled _) ->
      fail "accepted fence reported a write cancellation"
  | Ok Recovery.Dispatching_already ->
      fail "accepted fence reported dispatching"
  | Ok (Recovery.Visible_sync_unconfirmed _) ->
      fail "accepted fence was rewritten as prepared"
  | Error detail -> failf "same accepted fence became an error: %s" detail

let test_dispatch_claim_is_monotonic () =
  with_base "dispatch-claim" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  check (result unit string) "first claim" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "first dispatch" true (claim = Recovery.First_dispatch)));
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "dispatching recovery request" Recovery.Dispatching
  in
  check bool "dispatching identity" true
    (Chat.same_request_identity expected observed);
  (match Recovery.persist_pending ~base_path expected with
   | Ok Recovery.Dispatching_already -> ()
   | Ok _ -> fail "persist rewrote Dispatching to Prepared"
   | Error detail -> failf "dispatching observation failed: %s" detail);
  check (result unit string) "unclassified dispatch claim" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "dispatching is GET-only" true
         (claim = Recovery.Reconcile_dispatch)));
  Recovery.mark_replayable ~base_path expected
  |> expect_fsync "authorize exact replay";
  Recovery.mark_replayable ~base_path expected
  |> expect_fsync "reauthorize same exact replay";
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "replayable recovery request" Recovery.Replayable);
  check (result unit string) "replay claim" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "only replayable dispatch can POST" true
         (claim = Recovery.Replay_dispatch)));
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "replay claim returns to dispatching" Recovery.Dispatching);
  Recovery.mark_accepted ~base_path expected |> expect_fsync "accept";
  check (result unit string) "accepted claim" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "accepted dispatch" true
         (claim = Recovery.Accepted_dispatch)))

let test_dispatch_claim_before_rename_failure_blocks_callback () =
  with_base "dispatch-claim-before-rename" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let writer path _content =
    staged_error ~path ~stage:Fs_compat.Before_rename
      (Failure "claim write failed")
  in
  let callback_ran = ref false in
  (match
     Recovery.For_testing.with_dispatch_claim_with_writer
       ~save_file_atomic_strict_staged:writer ~base_path expected
       (fun _claim -> callback_ran := true)
   with
   | Error _ -> ()
   | Ok () -> fail "failed claim write authorized a callback");
  check bool "before-rename callback did not run" false !callback_ran;
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "prepared fence retained" Recovery.Prepared)

let test_dispatch_claim_after_rename_failure_blocks_callback () =
  with_base "dispatch-claim-after-rename" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let callback_ran = ref false in
  (match
     Recovery.For_testing.with_dispatch_claim_with_writer
       ~save_file_atomic_strict_staged:visible_after_rename_writer ~base_path
       expected (fun _claim -> callback_ran := true)
   with
   | Error detail ->
       check bool "claim sync failure is explicit" true
         (String.starts_with
            ~prefix:"Keeper chat dispatch claim sync is unconfirmed:" detail)
   | Ok () -> fail "sync-unconfirmed claim authorized a callback");
  check bool "after-rename callback did not run" false !callback_ran;
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "visible dispatching fence retained" Recovery.Dispatching)

let test_dispatch_claim_postcommit_cancellation_blocks_callback () =
  with_base "dispatch-claim-postcommit-cancel" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let writer ~on_durable_commit ~ownership_root:_ path content =
    Fs_compat.save_file path content;
    Unix.chmod path 0o600;
    on_durable_commit ();
    raise (Eio.Cancel.Cancelled (Failure "cancelled after claim commit"))
  in
  let staged_writer =
    Recovery.For_testing.save_file_durable_staged_with
      ~save_bytes_durable_atomic_observed:writer ~base_path
  in
  let callback_ran = ref false in
  (match
     Recovery.For_testing.with_dispatch_claim_with_writer
       ~save_file_atomic_strict_staged:staged_writer ~base_path expected
       (fun _claim -> callback_ran := true)
   with
   | Error detail ->
       check bool "claim cancellation is explicit" true
         (String.starts_with
            ~prefix:"Keeper chat dispatch claim was cancelled:" detail)
   | Ok () -> fail "postcommit claim cancellation authorized a callback");
  check bool "postcommit cancellation callback did not run" false !callback_ran;
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "durable dispatching fence retained" Recovery.Dispatching)

(* A dispatch that is still running is the ordinary case: the POST stays open
   until the turn's stream ends. Every TUI on the workspace shares one fence,
   so caller B has to reach it while caller A is mid-turn -- otherwise one turn
   that never settles silences every other TUI, and the escape the UI names for
   that (Ctrl-R) needs the same lock and fails with it (#29750).

   Letting B through costs no safety: it reads [Dispatching] and is handed
   [Reconcile_dispatch], which authorises no POST. Serialising the two only
   decided which answer B saw, not whether a second POST could happen. *)
let test_dispatch_in_flight_admits_other_callers () =
  with_base "dispatch-lock" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let mutex = Stdlib.Mutex.create () in
  let condition = Condition.create () in
  let first_entered = ref false in
  let release_first = ref false in
  let second_attempted = Atomic.make false in
  let second_entered = Atomic.make false in
  let first_result = ref None in
  let second_result = ref None in
  let run_first () =
    let result =
      Recovery.with_dispatch_claim ~base_path expected (fun claim ->
        check bool "caller A owns first dispatch" true
          (claim = Recovery.First_dispatch);
        Stdlib.Mutex.lock mutex;
        first_entered := true;
        Condition.broadcast condition;
        while not !release_first do
          Condition.wait condition mutex
        done;
        Stdlib.Mutex.unlock mutex;
        Recovery.mark_accepted ~base_path expected
        |> expect_fsync "caller A accept")
    in
    first_result := Some result
  in
  let first = Thread.create run_first () in
  Stdlib.Mutex.lock mutex;
  while not !first_entered do
    Condition.wait condition mutex
  done;
  Stdlib.Mutex.unlock mutex;
  let run_second () =
    Atomic.set second_attempted true;
    let result =
      Recovery.with_dispatch_claim ~base_path expected (fun claim ->
        Atomic.set second_entered true;
        check bool "caller B is authorised no second POST" true
          (claim = Recovery.Reconcile_dispatch))
    in
    second_result := Some result
  in
  let second = Thread.create run_second () in
  let deadline = Unix.gettimeofday () +. 2.0 in
  while not (Atomic.get second_attempted) && Unix.gettimeofday () < deadline do
    Thread.delay 0.001
  done;
  check bool "caller B attempted dispatch claim" true
    (Atomic.get second_attempted);
  let deadline = Unix.gettimeofday () +. 2.0 in
  while not (Atomic.get second_entered) && Unix.gettimeofday () < deadline do
    Thread.delay 0.001
  done;
  check bool "caller B reached the fence while caller A dispatches" true
    (Atomic.get second_entered);
  Stdlib.Mutex.lock mutex;
  release_first := true;
  Condition.broadcast condition;
  Stdlib.Mutex.unlock mutex;
  Thread.join first;
  Thread.join second;
  check (option (result unit string)) "caller A result" (Some (Ok ()))
    !first_result;
  check (option (result unit string)) "caller B result" (Some (Ok ()))
    !second_result;
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "caller A still owns the outcome" Recovery.Accepted)

(* Exclusion lives on the fence, not on a lock the caller holds across its own
   work. An external holder of the fence lock is the case that has to fail
   closed: while it is held nobody can read the phase and write the next one,
   so nobody may act on a claim. *)
let test_fence_lock_blocks_external_process () =
  with_base "dispatch-external-lock" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let lock_path = Recovery.recovery_path ~base_path ^ ".lock" in
  let ready_read, ready_write = Unix.pipe () in
  let release_read, release_write = Unix.pipe () in
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; "--hold-dispatch-lock"; lock_path |]
      release_read ready_write Unix.stderr
  in
  Unix.close ready_write;
  Unix.close release_read;
  let release () =
    Fun.protect
      ~finally:(fun () -> Unix.close release_write)
      (fun () ->
        check int "release external holder" 1
          (Unix.write_substring release_write "X" 0 1))
  in
  let wait_child () =
    let rec loop () =
      match Unix.waitpid [] pid with
      | result -> result
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    in
    loop ()
  in
  Fun.protect
    ~finally:(fun () ->
      release ();
      ignore (wait_child ()))
    (fun () ->
      let ready = Bytes.create 1 in
      check int "external holder ready byte" 1 (Unix.read ready_read ready 0 1);
      Unix.close ready_read;
      check char "external holder ready" 'R' (Bytes.get ready 0);
      let callback_ran = ref false in
      (match
         Recovery.with_dispatch_claim ~base_path expected (fun _claim ->
           callback_ran := true)
       with
       | Error detail ->
           check bool "lock contention is explicit" true
             (String.starts_with ~prefix:"Keeper chat recovery lock failed:"
                detail)
       | Ok () -> fail "a held fence lock admitted a claim");
      check bool "contended callback did not run" false !callback_ran)

let test_first_rejection_clears_before_stale_dispatch () =
  with_base "dispatch-rejection" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  check (result unit string) "first rejected dispatch" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "first rejection owns first dispatch" true
         (claim = Recovery.First_dispatch);
       check (result unit string) "clear rejected request" (Ok ())
         (Recovery.clear_pending ~base_path expected)));
  let stale_post_authorized = ref false in
  (match
     Recovery.with_dispatch_claim ~base_path expected (fun _claim ->
       stale_post_authorized := true)
   with
   | Error detail ->
       check bool "missing fence rejection" true
         (String.equal detail
            "Keeper chat recovery fence is missing before dispatch")
   | Ok () -> fail "stale caller was authorized after first rejection");
  check bool "stale caller issued zero dispatch callbacks" false
    !stale_post_authorized

let test_rejection_clear_failure_retains_no_dispatch_fence () =
  with_base "rejection-clear-failure" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  check (result unit string) "first rejected dispatch" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "rejection owns first dispatch" true
         (claim = Recovery.First_dispatch);
       Recovery.mark_rejected ~base_path expected
       |> expect_fsync "mark rejected";
       let remove_file _path = raise (Failure "remove failed before unlink") in
       match
         Recovery.For_testing.clear_pending_with_remover ~remove_file ~base_path
           expected
       with
       | Error detail ->
           check bool "rejection cleanup failure detail" true
             (String.starts_with
                ~prefix:"Keeper chat recovery clear failed:" detail)
       | Ok () -> fail "failed rejection cleanup removed the fence"));
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "rejected fence after clear failure" Recovery.Rejected
  in
  check bool "rejected identity retained" true
    (Chat.same_request_identity expected observed);
  check (result unit string) "stale claim is cleanup-only" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "rejected claim cannot replay" true
         (claim = Recovery.Rejected_dispatch)))

let test_rejection_marker_failure_leaves_get_only_dispatch () =
  with_base "rejection-marker-failure" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let writer path _content =
    staged_error ~path ~stage:Fs_compat.Before_rename
      (Failure "rejection marker write failed")
  in
  check (result unit string) "first rejected dispatch" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "rejection owns first dispatch" true
         (claim = Recovery.First_dispatch);
       match
         Recovery.For_testing.mark_rejected_with_writer
           ~save_file_atomic_strict_staged:writer ~base_path expected
       with
       | Error _ -> ()
       | Ok _ -> fail "failed rejection marker was reported durable"));
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "failed rejection marker stays dispatching"
          Recovery.Dispatching);
  check (result unit string) "stale caller is GET-only" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "failed rejection marker cannot replay" true
         (claim = Recovery.Reconcile_dispatch)))

let test_replay_marker_failure_leaves_get_only_dispatch () =
  with_base "replay-marker-failure" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let writer path _content =
    staged_error ~path ~stage:Fs_compat.Before_rename
      (Failure "replay marker write failed")
  in
  check (result unit string) "first uncertain dispatch" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "uncertain result owns first dispatch" true
         (claim = Recovery.First_dispatch);
       match
         Recovery.For_testing.mark_replayable_with_writer
           ~save_file_atomic_strict_staged:writer ~base_path expected
       with
       | Error _ -> ()
       | Ok _ -> fail "failed replay marker was reported durable"));
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "failed replay marker stays dispatching"
          Recovery.Dispatching);
  check (result unit string) "stale caller remains GET-only" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "failed replay marker cannot authorize POST" true
         (claim = Recovery.Reconcile_dispatch)))

let test_replay_authorization_rejects_invalid_source_phase () =
  with_base "replay-invalid-source" @@ fun base_path ->
  let expected = request () in
  (match Recovery.mark_replayable ~base_path expected with
   | Error _ -> ()
   | Ok _ -> fail "missing fence became replayable");
  check bool "missing replay fence was not created" false
    (Fs_compat.file_exists (Recovery.recovery_path ~base_path));
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  (match Recovery.mark_replayable ~base_path expected with
   | Error _ -> ()
   | Ok _ -> fail "prepared fence became replayable");
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "prepared phase retained" Recovery.Prepared);
  Recovery.mark_accepted ~base_path expected |> expect_fsync "accept";
  (match Recovery.mark_replayable ~base_path expected with
   | Error _ -> ()
   | Ok _ -> fail "accepted fence became replayable");
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "accepted phase retained" Recovery.Accepted);
  Recovery.clear_pending ~base_path expected
  |> check (result unit string) "clear accepted" (Ok ());
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare again";
  Recovery.mark_rejected ~base_path expected |> expect_fsync "reject";
  (match Recovery.mark_replayable ~base_path expected with
   | Error _ -> ()
   | Ok _ -> fail "rejected fence became replayable");
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "rejected phase retained" Recovery.Rejected)

let test_rejection_marker_cancellation_leaves_get_only_dispatch () =
  with_base "rejection-marker-cancel" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let writer path _content =
    staged_error ~path ~stage:Fs_compat.Before_rename
      (Eio.Cancel.Cancelled (Failure "rejection marker cancelled"))
  in
  let cancelled =
    try
      ignore
        (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
           check bool "cancelled rejection owns first dispatch" true
             (claim = Recovery.First_dispatch);
           ignore
             (Recovery.For_testing.mark_rejected_with_writer
                ~save_file_atomic_strict_staged:writer ~base_path expected)));
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  check bool "rejection marker cancellation re-raised" true cancelled;
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "cancelled rejection marker stays dispatching"
          Recovery.Dispatching);
  check (result unit string) "post-cancellation caller is GET-only" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "cancelled rejection marker cannot replay" true
         (claim = Recovery.Reconcile_dispatch)))

let test_replay_marker_cancellation_leaves_get_only_dispatch () =
  with_base "replay-marker-cancel" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  let writer path _content =
    staged_error ~path ~stage:Fs_compat.Before_rename
      (Eio.Cancel.Cancelled (Failure "replay marker cancelled"))
  in
  let cancelled =
    try
      ignore
        (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
           check bool "cancelled replay marker owns first dispatch" true
             (claim = Recovery.First_dispatch);
           ignore
             (Recovery.For_testing.mark_replayable_with_writer
                ~save_file_atomic_strict_staged:writer ~base_path expected)));
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  check bool "replay marker cancellation re-raised" true cancelled;
  ignore
    (Recovery.load_pending ~base_path
     |> expect_phase "cancelled replay marker stays dispatching"
          Recovery.Dispatching);
  check (result unit string) "post-cancellation replay is GET-only" (Ok ())
    (Recovery.with_dispatch_claim ~base_path expected (fun claim ->
       check bool "cancelled replay marker cannot authorize POST" true
         (claim = Recovery.Reconcile_dispatch)))

let test_clear_failure_retains_accepted_fence () =
  with_base "clear-failure" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  Recovery.mark_accepted ~base_path expected |> expect_fsync "accept";
  let remove_file _path = raise (Failure "remove failed") in
  (match
     Recovery.For_testing.clear_pending_with_remover ~remove_file ~base_path
       expected
   with
   | Error detail ->
       check bool "clear failure detail" true
         (String.starts_with ~prefix:"Keeper chat recovery clear failed:" detail)
   | Ok () -> fail "failed removal cleared the recovery fence");
  let observed =
    Recovery.load_pending ~base_path
    |> expect_phase "accepted fence after clear failure" Recovery.Accepted
  in
  check bool "accepted identity retained" true
    (Chat.same_request_identity expected observed)

let test_clear_post_unlink_failure_stays_loud () =
  with_base "clear-post-unlink" @@ fun base_path ->
  let expected = request () in
  Recovery.persist_pending ~base_path expected |> expect_fsync "prepare";
  Recovery.mark_accepted ~base_path expected |> expect_fsync "accept";
  let calls = ref 0 in
  let remove_file path =
    incr calls;
    if !calls = 1 then begin
      Sys.remove path;
      raise (Failure "parent sync failed")
    end
  in
  (match
     Recovery.For_testing.clear_pending_with_remover ~remove_file ~base_path
       expected
   with
   | Error detail ->
       check bool "post-unlink failure detail" true
         (String.starts_with ~prefix:"Keeper chat recovery clear failed:" detail)
   | Ok () -> fail "post-unlink parent sync failure was hidden");
  check bool "unlink remained visible" false
    (Fs_compat.file_exists (Recovery.recovery_path ~base_path));
  check (result unit string) "missing-file retry completes parent sync" (Ok ())
    (Recovery.For_testing.clear_pending_with_remover ~remove_file ~base_path
       expected);
  check int "durable remover retried after visible unlink" 2 !calls

let test_durable_remove_adapter_classifies_visible_cancellation () =
  with_base "durable-remove-visible-cancel" @@ fun base_path ->
  let path = Recovery.recovery_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path "fence\n";
  let remover ~ownership_root:_ path =
    Sys.remove path;
    raise (Eio.Cancel.Cancelled (Failure "cancelled after unlink"))
  in
  let stayed_loud =
    try
      Recovery.For_testing.remove_file_durable_with
        ~remove_file_durable:remover ~base_path path;
      false
    with Failure detail ->
      String.starts_with
        ~prefix:"durable removal cancelled after the fence became absent:"
        detail
  in
  check bool "visible unlink cancellation became retryable error" true stayed_loud;
  check bool "unlink visible" false (Sys.file_exists path)

let test_durable_remove_adapter_reraises_preunlink_cancellation () =
  with_base "durable-remove-preunlink-cancel" @@ fun base_path ->
  let path = Recovery.recovery_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path "fence\n";
  let remover ~ownership_root:_ _path =
    raise (Eio.Cancel.Cancelled (Failure "cancelled before unlink"))
  in
  let raised =
    try
      Recovery.For_testing.remove_file_durable_with
        ~remove_file_durable:remover ~base_path path;
      false
    with Eio.Cancel.Cancelled _ -> true
  in
  check bool "preunlink cancellation re-raised" true raised;
  check bool "fence retained" true (Sys.file_exists path)

let test_restart_phase_routes_one_callback () =
  let request = request () in
  let prepared_calls = ref 0 in
  let dispatching_get_calls = ref 0 in
  let replay_calls = ref 0 in
  let accepted_calls = ref 0 in
  let rejected_calls = ref 0 in
  let retry_prepared _ = incr prepared_calls in
  let reconcile_dispatching _ = incr dispatching_get_calls in
  let retry_replayable _ = incr replay_calls in
  let reconcile_accepted _ = incr accepted_calls in
  let cleanup_rejected _ = incr rejected_calls in
  Recovery.resume_pending { request; phase = Recovery.Prepared }
    ~retry_prepared ~reconcile_dispatching ~retry_replayable
    ~reconcile_accepted ~cleanup_rejected;
  check int "prepared retry count" 1 !prepared_calls;
  check int "prepared dispatching GET count" 0 !dispatching_get_calls;
  check int "prepared replay count" 0 !replay_calls;
  check int "prepared GET count" 0 !accepted_calls;
  check int "prepared cleanup count" 0 !rejected_calls;
  prepared_calls := 0;
  Recovery.resume_pending { request; phase = Recovery.Dispatching }
    ~retry_prepared ~reconcile_dispatching ~retry_replayable
    ~reconcile_accepted ~cleanup_rejected;
  check int "dispatching prepared count" 0 !prepared_calls;
  check int "dispatching GET count" 1 !dispatching_get_calls;
  check int "dispatching replay count" 0 !replay_calls;
  check int "dispatching GET count" 0 !accepted_calls;
  check int "dispatching cleanup count" 0 !rejected_calls;
  dispatching_get_calls := 0;
  Recovery.resume_pending { request; phase = Recovery.Replayable }
    ~retry_prepared ~reconcile_dispatching ~retry_replayable
    ~reconcile_accepted ~cleanup_rejected;
  check int "replayable prepared count" 0 !prepared_calls;
  check int "replayable dispatching GET count" 0 !dispatching_get_calls;
  check int "replayable replay count" 1 !replay_calls;
  check int "replayable accepted GET count" 0 !accepted_calls;
  check int "replayable cleanup count" 0 !rejected_calls;
  replay_calls := 0;
  Recovery.resume_pending { request; phase = Recovery.Accepted }
    ~retry_prepared ~reconcile_dispatching ~retry_replayable
    ~reconcile_accepted ~cleanup_rejected;
  check int "accepted POST count" 0 !prepared_calls;
  check int "accepted dispatching GET count" 0 !dispatching_get_calls;
  check int "accepted replay count" 0 !replay_calls;
  check int "accepted GET count" 1 !accepted_calls;
  check int "accepted cleanup count" 0 !rejected_calls;
  accepted_calls := 0;
  Recovery.resume_pending { request; phase = Recovery.Rejected }
    ~retry_prepared ~reconcile_dispatching ~retry_replayable
    ~reconcile_accepted ~cleanup_rejected;
  check int "rejected POST count" 0 !prepared_calls;
  check int "rejected dispatching GET count" 0 !dispatching_get_calls;
  check int "rejected replay count" 0 !replay_calls;
  check int "rejected GET count" 0 !accepted_calls;
  check int "rejected cleanup count" 1 !rejected_calls

let () =
  run "tui_keeper_chat_recovery"
    [ ( "recovery"
      , [ test_case "round trip, accept, and clear" `Quick
            test_round_trip_accept_and_clear
        ; test_case "conflict fails closed" `Quick test_conflict_fails_closed
        ; test_case "malformed fails closed" `Quick test_malformed_fails_closed
        ; test_case "v2 recovery is hard cut" `Quick test_v2_record_is_hard_cut
        ; test_case "bounded poll budget" `Quick test_bounded_poll_budget
        ; test_case "after rename retains prepared" `Quick
            test_after_rename_retains_prepared_without_dispatch
        ; test_case "before rename fails closed" `Quick
            test_before_rename_failure_leaves_no_fence
        ; test_case "before rename cancellation stays loud" `Quick
            test_before_rename_cancellation_stays_loud
        ; test_case "after rename cancellation is typed" `Quick
            test_after_rename_cancellation_is_visible_unconfirmed
        ; test_case "durable adapter observes postcommit cancellation" `Quick
            test_durable_adapter_records_postcommit_cancellation
        ; test_case "durable adapter reraises prewrite cancellation" `Quick
            test_durable_adapter_reraises_prewrite_cancellation
        ; test_case "durable adapter requires commit observation" `Quick
            test_durable_adapter_requires_commit_observation
        ; test_case "accepted after rename is typed" `Quick
            test_accepted_after_rename_is_typed
        ; test_case "accepted phase recreates missing fence" `Quick
            test_mark_accepted_recreates_missing_fence
        ; test_case "persist observes cross-process acceptance" `Quick
            test_persist_observes_cross_process_acceptance
        ; test_case "dispatch claim is monotonic" `Quick
            test_dispatch_claim_is_monotonic
        ; test_case "claim before-rename failure blocks callback" `Quick
            test_dispatch_claim_before_rename_failure_blocks_callback
        ; test_case "claim after-rename failure blocks callback" `Quick
            test_dispatch_claim_after_rename_failure_blocks_callback
        ; test_case "claim postcommit cancellation blocks callback" `Quick
            test_dispatch_claim_postcommit_cancellation_blocks_callback
        ; test_case "dispatch in flight admits other callers" `Quick
            test_dispatch_in_flight_admits_other_callers
        ; test_case "fence lock blocks external process" `Slow
            test_fence_lock_blocks_external_process
        ; test_case "first rejection blocks stale dispatch" `Quick
            test_first_rejection_clears_before_stale_dispatch
        ; test_case "rejection cleanup failure blocks replay" `Quick
            test_rejection_clear_failure_retains_no_dispatch_fence
        ; test_case "rejection marker failure remains GET-only" `Quick
            test_rejection_marker_failure_leaves_get_only_dispatch
        ; test_case "replay marker failure remains GET-only" `Quick
            test_replay_marker_failure_leaves_get_only_dispatch
        ; test_case "replay authorization rejects invalid source" `Quick
            test_replay_authorization_rejects_invalid_source_phase
        ; test_case "rejection marker cancellation remains GET-only" `Quick
            test_rejection_marker_cancellation_leaves_get_only_dispatch
        ; test_case "replay marker cancellation remains GET-only" `Quick
            test_replay_marker_cancellation_leaves_get_only_dispatch
        ; test_case "clear failure retains accepted fence" `Quick
            test_clear_failure_retains_accepted_fence
        ; test_case "post-unlink clear failure stays loud" `Quick
            test_clear_post_unlink_failure_stays_loud
        ; test_case "durable remover types visible cancellation" `Quick
            test_durable_remove_adapter_classifies_visible_cancellation
        ; test_case "durable remover reraises preunlink cancellation" `Quick
            test_durable_remove_adapter_reraises_preunlink_cancellation
        ; test_case "restart phase routes one callback" `Quick
            test_restart_phase_routes_one_callback
        ] )
    ]
