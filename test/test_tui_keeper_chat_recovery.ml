open Alcotest

module Chat = Masc_tui_keeper_chat_projection
module Recovery = Masc_tui_keeper_chat_recovery

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
    {|{"schema":"masc.tui_keeper_chat_recovery.v2","phase":"prepared","request_id":"bad","keeper_name":"keeper.one","message":"hello","extra":true}|};
  match Recovery.load_pending ~base_path with
  | Error _ -> ()
  | Ok _ -> fail "malformed recovery record was accepted"

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
  | Ok (Recovery.Visible_sync_unconfirmed _) ->
      fail "accepted fence was rewritten as prepared"
  | Error detail -> failf "same accepted fence became an error: %s" detail

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
  let accepted_calls = ref 0 in
  let retry_prepared _ = incr prepared_calls in
  let reconcile_accepted _ = incr accepted_calls in
  Recovery.resume_pending { request; phase = Recovery.Prepared }
    ~retry_prepared ~reconcile_accepted;
  check int "prepared retry count" 1 !prepared_calls;
  check int "prepared GET count" 0 !accepted_calls;
  prepared_calls := 0;
  Recovery.resume_pending { request; phase = Recovery.Accepted }
    ~retry_prepared ~reconcile_accepted;
  check int "accepted POST count" 0 !prepared_calls;
  check int "accepted GET count" 1 !accepted_calls

let () =
  run "tui_keeper_chat_recovery"
    [ ( "recovery"
      , [ test_case "round trip, accept, and clear" `Quick
            test_round_trip_accept_and_clear
        ; test_case "conflict fails closed" `Quick test_conflict_fails_closed
        ; test_case "malformed fails closed" `Quick test_malformed_fails_closed
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
