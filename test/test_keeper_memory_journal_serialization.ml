open Alcotest

module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types

let keeper_id = "keeper"

let with_keepers_dir f =
  let path = Filename.temp_file "memory-journal-serialization-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

let require_ok = function
  | Ok value -> value
  | Error message -> fail message
;;

let append_failure ~keepers_dir ~keeper_id ~trace_id =
  Current.append_librarian_failure
    ~keepers_dir ~keeper_id ~now:300.0 ~trace_id
    ~kind:Current.Exact_execution_failure
    ~detail:("failure evidence for " ^ trace_id) ~snapshot_present:true
;;

let failure_row ~keepers_dir =
  let keeper_id = "row-fixture" in
  append_failure ~keepers_dir ~keeper_id ~trace_id:"live-row";
  Fs_compat.load_file
    (Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id)
;;

let rec write_all fd text offset =
  if offset < String.length text then
    match Unix.write_substring fd text offset (String.length text - offset) with
    | 0 -> fail "pipe or journal write made no progress"
    | written -> write_all fd text (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd text offset
;;

let rec waitpid child =
  match Unix.waitpid [] child with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid child
;;

let await_signal fd =
  (* These deadlines bound a broken test process, never a Keeper operation. *)
  let readable, _, _ = Unix.select [ fd ] [] [] 5.0 in
  if readable = [] then fail "journal child did not reach its pipe barrier";
  let byte = Bytes.create 1 in
  match Unix.read fd byte 0 1 with
  | 1 -> Bytes.get byte 0
  | _ -> fail "journal child exited before its pipe barrier"
;;

let with_live_partial_row ~path ~row action =
  (match Fs_compat.recover_private_jsonl_durable_locked_result path with
   | Ok _ -> ()
   | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error));
  let lock_fd =
    Unix.openfile (Fs_compat.private_jsonl_lock_path path)
      [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0
  in
  let lock_closed = ref false in
  let close_lock () =
    if not !lock_closed then (
      lock_closed := true;
      Unix.close lock_fd)
  in
  Fun.protect ~finally:close_lock @@ fun () ->
  Unix.lockf lock_fd Unix.F_LOCK 0;
  let original = Fs_compat.load_file path in
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_APPEND; Unix.O_CLOEXEC ] 0 in
  let closed = ref false in
  let close_journal () =
    if not !closed then (
      closed := true;
      Unix.close fd)
  in
  Fun.protect ~finally:close_journal @@ fun () ->
  let split = String.length row / 2 in
  let prefix = String.sub row 0 split in
  write_all fd prefix 0;
  Unix.fsync fd;
  (* A dashboard/archive read closes another data descriptor in this process.
     It must not release the cross-process writer lock on the sibling file. *)
  check string "ordinary data read preserves the live prefix" (original ^ prefix)
    (Fs_compat.load_file path);
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 ->
    Unix.close read_end;
    (* POSIX record locks belong to the parent process, not inherited fds. *)
    Unix.close lock_fd;
    Unix.close fd;
    (try
       write_all write_end "R" 0;
       action ();
       write_all write_end "D" 0;
       Unix.close write_end;
       Unix._exit 0
     with exn ->
       prerr_endline (Printexc.to_string exn);
       Unix._exit 2)
  | child ->
    Unix.close write_end;
    let reaped = ref false in
    Fun.protect
      ~finally:(fun () ->
        close_journal ();
        close_lock ();
        Unix.close read_end;
        if not !reaped then (
          (try Unix.kill child Sys.sigkill with
           | Unix.Unix_error (Unix.ESRCH, _, _) -> ());
          ignore (waitpid child : Unix.process_status)))
      (fun () ->
        check char "child reached append/recovery barrier" 'R' (await_signal read_end);
        (* Stable-lock contention returns without changing the journal. Wait
           for the actual operation to return while the writer still owns the
           lock; the test needs no timing assumption about child scheduling. *)
        check char "child reports contention while writer owns lock" 'D'
          (await_signal read_end);
        let status = waitpid child in
        reaped := true;
        check bool "child exited successfully" true (status = Unix.WEXITED 0);
        check string "contended recovery and append leave all live bytes unchanged"
          (original ^ prefix) (Fs_compat.load_file path);
        write_all fd (String.sub row split (String.length row - split)) 0;
        Unix.fsync fd;
        close_journal ();
        close_lock ())
;;

let journal ~keepers_dir =
  Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10
  |> List.map require_ok
;;

let failure_traces entries =
  List.filter_map
    (function
      | Current.Journal_failed { trace_id; _ } -> Some trace_id
      | Current.Journal_committed _ | Current.Journal_quarantined _ -> None)
    entries
;;

let test_failure_append_preserves_live_row () =
  with_keepers_dir @@ fun keepers_dir ->
  append_failure ~keepers_dir ~keeper_id ~trace_id:"before";
  let row = failure_row ~keepers_dir in
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  with_live_partial_row ~path ~row (fun () ->
    append_failure ~keepers_dir ~keeper_id ~trace_id:"concurrent");
  check (list string) "contended failure append leaves the live row intact"
    [ "before"; "live-row" ] (failure_traces (journal ~keepers_dir));
  append_failure ~keepers_dir ~keeper_id ~trace_id:"concurrent";
  check (list string) "all failure rows survive in append order"
    [ "before"; "live-row"; "concurrent" ]
    (failure_traces (journal ~keepers_dir))
;;

let test_receipt_recovery_preserves_live_row () =
  with_keepers_dir @@ fun keepers_dir ->
  let target : Types.fact =
    Types.observed ~claim:"original retained through interrupted removal"
      ~category:Types.Fact ~now:100.0
      ~origin:{ kind = Types.Authored; trace_id = "seed" }
  in
  let seeded =
    Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:200.0
      ~source:{ kind = Current.Librarian; trace_id = "seed" } ~facts:[ target ] ()
    |> require_ok
  in
  let snapshot_sha256 =
    match Current.read_with_snapshot_sha256 ~keepers_dir ~keeper_id with
    | Ok (Some (_, hash)) -> hash
    | Ok None | Error _ -> fail "seeded snapshot hash is unavailable"
  in
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let seed_journal = Fs_compat.load_file path in
  Fs_compat.invalidate_cached_writer path;
  Sys.remove path;
  Unix.mkdir path 0o700;
  let plan_id = "interrupted-removal" in
  let reason = "operator verified this original is obsolete" in
  let request () =
    Current.retract_facts ~keepers_dir ~keeper_id
      ~expected_revision:seeded.revision ~expected_snapshot_sha256:snapshot_sha256
      ~now:250.0 ~source:{ kind = Current.Explicit_retract; trace_id = plan_id }
      [ { Current.memory_id = Types.memory_id target; reason } ]
  in
  (match request () with
   | Error (Current.Retract_batch_plan_evidence_pending _) -> ()
   | Error _ | Ok _ -> fail "fixture did not preserve the committed removal receipt");
  let receipt = Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  check bool "interrupted removal has durable recovery evidence" true
    (Sys.file_exists receipt);
  let prepared_receipt = Fs_compat.load_file receipt in
  Unix.rmdir path;
  Fs_compat.save_file path seed_journal;
  let row = failure_row ~keepers_dir in
  with_live_partial_row ~path ~row (fun () ->
    match request () with
    | Error (Current.Retract_batch_persistence_failed _) -> ()
    | Error _ | Ok _ -> fail "contended recovery did not preserve the pending receipt");
  check string "contended recovery retains exact prepared evidence" prepared_receipt
    (Fs_compat.load_file receipt);
  (match request () with
   | Error (Current.Retract_batch_snapshot_conflict _) -> ()
   | Error _ | Ok _ -> fail "reconciliation did not precede the stale request");
  check bool "recovered receipt is cleared" false (Sys.file_exists receipt);
  let entries = journal ~keepers_dir in
  check int "seed, live failure, and removal remain complete" 3 (List.length entries);
  check (list string) "live failure survives receipt recovery" [ "live-row" ]
    (failure_traces entries);
  (match List.rev entries with
   | Current.Journal_committed { source; dropped = Some [ dropped ]; _ } :: _ ->
     check string "removal retains plan identity" plan_id source.trace_id;
     check string "removal retains original identity" (Types.memory_id target)
       dropped.memory_id;
     check string "removal retains exact reason" reason dropped.reason
   | _ -> fail "recovery did not append the exact removal evidence");
  (match Current.read_dropped ~keepers_dir ~keeper_id ~current_facts:[] |> require_ok with
   | [ archived ] ->
     check bool "archive retains the complete original" true (archived.original = target);
     check (option string) "archive retains the exact reason" (Some reason)
       archived.removal.drop_reason
   | _ -> fail "recovery lost or duplicated the archived original")
;;

let () =
  run "keeper memory journal serialization"
    [ ( "cross-process journal writers"
      , [ test_case "failure append preserves a live partial row" `Quick
            test_failure_append_preserves_live_row
        ; test_case "receipt recovery preserves a live partial row" `Quick
            test_receipt_recovery_preserves_live_row
        ] ) ]
;;
