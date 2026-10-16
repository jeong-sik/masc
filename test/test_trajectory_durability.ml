(** Real locked fd transactions, injected write/rollback failures, and
    accumulator ownership across failed finalization and later turns. *)
module T = Trajectory
module B = Trajectory_buffer
module P = Trajectory_persistence

let with_root f =
  let root = Filename.temp_file "trajectory-durability-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () -> f root)

let create ?on_flush_error root trace_id =
  T.create_accumulator ?on_flush_error ~masc_root:root ~keeper_name:"keeper" ~trace_id ()

let entry tool_name : T.tool_call_entry =
  { ts=1.; ts_iso="2026-10-16T00:00:00Z"; turn=1; round=1; tool_name
  ; args_json="{}"; gate_decision=T.Pass; result=Some "ok"; duration_ms=1
  ; error=None; execution_id=None }

let record acc name =
  match T.record_entry acc (entry name) with
  | T.Recorded -> ()
  | T.Recorder_closed -> Alcotest.fail "recording closed before acceptance"

let path root trace_id = T.trajectory_path root "keeper" trace_id

let labels root trace_id =
  if not (Sys.file_exists (path root trace_id)) then []
  else
    let ic = open_in_bin (path root trace_id) in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let rec read acc =
        match input_line ic with
        | line ->
          let json = Yojson.Safe.from_string line in
          let label = match Yojson.Safe.Util.member "type" json with
            | `String "trajectory_summary" -> "summary"
            | _ -> Yojson.Safe.Util.(json |> member "tool_name" |> to_string)
          in read (label :: acc)
        | exception End_of_file -> List.rev acc
      in read [])

let finalized acc =
  match T.finalize acc T.Completed with
  | T.Finalized trajectory -> trajectory
  | T.Finalization_pending state ->
    Alcotest.failf "finalization pending: %s" (B.outcome_label state)

let expect_retryable = function
  | B.Retryable_failure _ -> ()
  | state -> Alcotest.failf "expected recoverable failure, got %s" (B.outcome_label state)

let expect_indeterminate = function
  | B.Indeterminate_failure _ -> ()
  | state -> Alcotest.failf "expected indeterminate failure, got %s" (B.outcome_label state)

let unix_io : Fs_compat.durable_append_io_for_testing =
  {write=Unix.write; ftruncate=Unix.ftruncate; fsync=Unix.fsync}

let test_prewrite_callback_and_later_turn () =
  with_root @@ fun root ->
  let obstacle = Filename.concat root "obstacle" in
  let oc = open_out obstacle in close_out oc;
  let calls = ref 0 in
  let old = create ~on_flush_error:(fun _ -> incr calls; failwith "reporter failed") obstacle "shared" in
  record old "first";
  (match T.finalize old T.Completed with
   | T.Finalization_pending (B.Retryable_failure _) -> ()
   | _ -> Alcotest.fail "failed write returned a successful summary");
  Alcotest.(check int) "callback called outside writer ownership" 1 !calls;
  Alcotest.(check int) "tool and summary retained" 2 (T.For_testing.pending_depth old);
  Alcotest.(check bool) "failed finalization stays active" false (T.For_testing.finalized old);
  let later = create obstacle "shared" in
  record later "later";
  Alcotest.(check int) "later turn shares previous FIFO" 3 (T.For_testing.pending_depth later);
  Unix.unlink obstacle;
  Unix.mkdir obstacle 0o700;
  T.flush_all_pending ();
  Alcotest.(check bool) "background flush settles previous summary" true (T.For_testing.finalized old);
  ignore (finalized later : T.trajectory);
  ignore (finalized old : T.trajectory);
  Alcotest.(check (list string)) "FIFO and one summary per accumulator"
    ["first"; "summary"; "later"; "summary"] (labels obstacle "shared");
  Alcotest.(check bool) "late record refused explicitly" true
    (T.record_entry old (entry "too-late") = T.Recorder_closed)

let partial_io ~rollback_fails ~attempts =
  { unix_io with
    write=(fun fd bytes offset length ->
      incr attempts;
      if !attempts = 1 then Unix.write fd bytes offset (min 7 length)
      else raise (Unix.Unix_error (Unix.ENOSPC, "write", "fixture")))
  ; ftruncate=(fun fd length ->
      if rollback_fails then raise (Unix.Unix_error (Unix.EIO, "ftruncate", "fixture"))
      else Unix.ftruncate fd length)
  }

let fault_acc root trace_id append =
  T.For_testing.create_accumulator_with_append ~append
    ~masc_root:root ~keeper_name:"keeper" ~trace_id ()

let test_partial_rollback_retry () =
  with_root @@ fun root ->
  let attempts = ref 0 and failing = ref true in
  let io = partial_io ~rollback_fails:false ~attempts in
  let acc = fault_acc root "rollback" (fun ~path jsons ->
    if !failing then P.For_testing.append_with_io ~append_io:io ~path jsons
    else P.append ~path jsons) in
  record acc "one"; record acc "two";
  expect_retryable (T.flush_pending acc);
  Alcotest.(check int) "rollback really removed partial bytes" 0 (Unix.stat (path root "rollback")).Unix.st_size;
  Alcotest.(check int) "both rows still owned" 2 (T.For_testing.pending_depth acc);
  failing := false;
  record acc "three";
  ignore (finalized acc : T.trajectory);
  Alcotest.(check (list string)) "retry exactly once in accepted order"
    ["one"; "two"; "three"; "summary"] (labels root "rollback")

let test_failed_rollback_blocks_only_its_trace () =
  with_root @@ fun root ->
  let attempts = ref 0 in
  let io = partial_io ~rollback_fails:true ~attempts in
  let broken = fault_acc root "unknown" (P.For_testing.append_with_io ~append_io:io) in
  record broken "unknown-row";
  expect_indeterminate (T.flush_pending broken);
  let written = (Unix.stat (path root "unknown")).Unix.st_size in
  Alcotest.(check bool) "actual partial bytes preserved" true (written > 0);
  let before = !attempts in
  (match T.finalize broken T.Completed with
   | T.Finalization_pending (B.Blocked _) -> ()
   | _ -> Alcotest.fail "unknown commit was retried or finalized");
  let healthy = create root "healthy" in
  record healthy "healthy-row";
  ignore (finalized healthy : T.trajectory);
  T.flush_all_pending ();
  Alcotest.(check int) "unknown trace never blindly retries" before !attempts;
  Alcotest.(check int) "partial bytes not truncated" written (Unix.stat (path root "unknown")).Unix.st_size;
  Alcotest.(check int) "unknown tool and summary stay owned" 2 (T.For_testing.pending_depth broken);
  Alcotest.(check (list string)) "unrelated trace keeps making progress"
    ["healthy-row"; "summary"] (labels root "healthy")

let test_unexpected_exception_after_actual_write () =
  with_root @@ fun root ->
  let attempts = ref 0 in
  let io = {unix_io with write=(fun fd bytes offset length ->
    incr attempts;
    let count = Unix.write fd bytes offset length in
    Unix.fsync fd;
    if count > 0 then failwith "acknowledgment interrupted";
    count)} in
  let acc = fault_acc root "lost-ack" (P.For_testing.append_with_io ~append_io:io) in
  record acc "actually-written";
  expect_indeterminate (T.flush_pending acc);
  Alcotest.(check (list string)) "real complete row exists despite unknown acknowledgment"
    ["actually-written"] (labels root "lost-ack");
  (match T.flush_pending acc with B.Blocked _ -> () | _ -> Alcotest.fail "lost ack retried");
  Alcotest.(check int) "writer called once" 1 !attempts;
  Alcotest.(check int) "unknown row remains owned" 1 (T.For_testing.pending_depth acc)

let test_incomplete_existing_tail_is_preserved () =
  with_root @@ fun root ->
  let acc = create root "tail" in
  let file = path root "tail" in
  Fs_compat.mkdir_p (Filename.dirname file);
  let oc = open_out_bin file in output_string oc "{partial"; close_out oc;
  record acc "next";
  expect_retryable (T.flush_pending acc);
  let ic = open_in_bin file in
  let bytes = really_input_string ic (in_channel_length ic) in close_in ic;
  Alcotest.(check string) "unacknowledged existing bytes preserved" "{partial" bytes;
  Alcotest.(check int) "new row remains owned" 1 (T.For_testing.pending_depth acc)

let test_concurrent_enqueue_during_actual_transaction () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_root @@ fun root ->
  let entered, publish_entered = Eio.Promise.create () in
  let release, publish_release = Eio.Promise.create () in
  let first = Atomic.make true in
  let acc = fault_acc root "concurrent" (fun ~path jsons ->
    if Atomic.compare_and_set first true false then begin
      Eio.Promise.resolve publish_entered ();
      Eio.Promise.await release
    end;
    P.append ~path jsons) in
  record acc "first";
  Eio.Fiber.both
    (fun () -> match T.flush_pending acc with
      | B.Flushed {rows=1; cleanup_failure=None} -> ()
      | state -> Alcotest.failf "first transaction: %s" (B.outcome_label state))
    (fun () ->
      Eio.Promise.await entered;
      record acc "second";
      Alcotest.(check bool) "another flush never steals active batch" true
        (T.flush_pending acc = B.Busy);
      Eio.Promise.resolve publish_release ());
  Alcotest.(check int) "new enqueue retained after prefix acknowledgment" 1 (T.For_testing.pending_depth acc);
  ignore (finalized acc : T.trajectory);
  Alcotest.(check (list string)) "no reordering or loss during write"
    ["first"; "second"; "summary"] (labels root "concurrent")

let test_cancellation_after_write_keeps_acknowledgment () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_root @@ fun root ->
  let written, publish_written = Eio.Promise.create () in
  let context, publish_context = Eio.Promise.create () in
  let mu = Stdlib.Mutex.create () and gate = Stdlib.Condition.create () in
  let released = ref false and cancellation_seen = ref false in
  let io = {unix_io with fsync=(fun fd ->
    Unix.fsync fd;
    Eio.Promise.resolve publish_written ();
    Stdlib.Mutex.protect mu (fun () ->
      while not !released do Stdlib.Condition.wait gate mu done))} in
  let acc = fault_acc root "cancel-ack" (P.For_testing.append_with_io ~append_io:io) in
  record acc "committed-before-cancel";
  Eio.Fiber.both
    (fun () ->
      Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve publish_context cc;
        try
          ignore (T.flush_pending acc : B.outcome);
          Eio.Fiber.check ()
        with Eio.Cancel.Cancelled _ -> cancellation_seen := true))
    (fun () ->
      let cc = Eio.Promise.await context in
      Eio.Promise.await written;
      Eio.Cancel.cancel cc (Failure "fixture cancellation after real fsync");
      Stdlib.Mutex.protect mu (fun () -> released := true; Stdlib.Condition.signal gate));
  Alcotest.(check bool) "cancellation delivered after protected commit" true !cancellation_seen;
  Alcotest.(check int) "durable row no longer pending" 0 (T.For_testing.pending_depth acc);
  Alcotest.(check (list string)) "durable row exists once"
    ["committed-before-cancel"] (labels root "cancel-ack");
  (match T.flush_pending acc with B.Empty -> () | _ -> Alcotest.fail "committed row was retried")

let () = Alcotest.run "Trajectory durable ownership"
  ["failures", [
    Alcotest.test_case "prewrite callback and later turn" `Quick test_prewrite_callback_and_later_turn;
    Alcotest.test_case "partial write rollback and retry" `Quick test_partial_rollback_retry;
    Alcotest.test_case "failed rollback isolates trace" `Quick test_failed_rollback_blocks_only_its_trace;
    Alcotest.test_case "lost acknowledgment after actual write" `Quick test_unexpected_exception_after_actual_write;
    Alcotest.test_case "existing incomplete tail" `Quick test_incomplete_existing_tail_is_preserved;
    Alcotest.test_case "concurrent accepted FIFO" `Quick test_concurrent_enqueue_during_actual_transaction;
    Alcotest.test_case "cancel after fsync retains acknowledgment" `Quick test_cancellation_after_write_keeps_acknowledgment;
  ]]
