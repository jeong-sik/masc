open Alcotest
module D = Masc.Lane_addon_broadcast_delivery
let require = function Ok v -> v | Error _ -> fail "delivery ledger refused"
let recovery_failure = function
  | Ok (recovery : D.recovery) -> (match recovery.rejected with
      | [(_,error)] -> Error error | _ -> Ok recovery)
  | Error error -> Error error
let rec remove path = if Sys.is_directory path then (
  Array.iter (fun child -> remove (Filename.concat path child)) (Sys.readdir path);
  Unix.rmdir path) else Sys.remove path
let fixture f =
  let root=Filename.temp_file "fleet-ledger" ".fixture" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root (D.create ~root))
let operation = require (D.Request_id.of_string "evidence-request-1")
let payload : D.payload = {sender_authority=D.External_sender;caller="operator";operation_id=operation;
  artifact_sha256=String.make 64 'a';content="Original immutable evidence pointer";
  recipients=["keeper-a";"keeper-b"]}
let test_restart_and_partial_fanout () = fixture (fun root ledger ->
  let accepted=require (D.admit ledger payload) in
  check bool "admission does not fabricate workspace commit" true
    (accepted.record.workspace=D.Uncommitted && not (D.complete accepted.record));
  let reopen () = D.create ~root in
  let pending=(require (D.recover (reopen ()))).pending in
  check int "unfinished commit is discoverable after restart" 1 (List.length pending);
  let committed=require (D.commit ledger ~caller:payload.caller ~operation_id:operation ~seq:7) in
  check bool "commit preserves exact producer request identity" true
    (D.Request_id.equal accepted.record.workspace_request_id committed.record.workspace_request_id);
  let _accepted=require (D.recipient_result ledger ~caller:payload.caller ~operation_id:operation
    ~recipient:"keeper-a" D.Accepted) in
  let failed=require (D.recipient_result ledger ~caller:payload.caller ~operation_id:operation
    ~recipient:"keeper-b" (D.Pending (Some "transcript store unavailable"))) in
  check bool "failed recipient keeps its obligation" false (D.complete failed.record);
  check bool "pending reset cannot erase failed-attempt evidence" true
    (D.recipient_result ledger ~caller:payload.caller ~operation_id:operation
      ~recipient:"keeper-b" (D.Pending None)=Error D.Conflict);
  let retained=require (D.find (reopen ()) ~caller:payload.caller ~operation_id:operation) in
  check bool "refused reset retains latest failure after restart" true
    (match retained with
     | Some receipt -> List.assoc "keeper-b" receipt.record.recipients =
         D.Pending (Some "transcript store unavailable")
     | None -> false);
  let recovered=(require (D.recover (reopen ()))).pending |> List.hd in
  check bool "partial fanout retains accepted and failed recipients exactly" true
    (recovered.record.recipients=["keeper-a",D.Accepted;
      "keeper-b",D.Pending (Some "transcript store unavailable")]);
  let replay=require (D.admit (reopen ()) payload) in
  check bool "same operation replay retains workspace identity and sequence" true
    (replay.record.workspace=D.Committed 7 && D.Request_id.equal
      accepted.record.workspace_request_id replay.record.workspace_request_id);
  check bool "accepted recipients cannot be made pending" true
    (D.recipient_result ledger ~caller:payload.caller ~operation_id:operation
      ~recipient:"keeper-a" (D.Pending None)=Error D.Conflict);
  let finished=require (D.recipient_result ledger ~caller:payload.caller ~operation_id:operation
    ~recipient:"keeper-b" D.Accepted) in
  check bool "all exact recipients accepted completes projection only" true (D.complete finished.record);
  check int "completed obligation excluded from drain" 0 (List.length (require (D.recover (reopen ()))).pending))
let test_collision_and_unknown_states () = fixture (fun root ledger ->
  let _admitted=require (D.admit ledger payload) in
  List.iter (fun replacement -> check bool "same key cannot replace evidence or audience" true
    (D.admit ledger replacement=Error D.Conflict))
    [{payload with sender_authority=D.Keeper_sender};{payload with content="different"};{payload with artifact_sha256=String.make 64 'b'};
     {payload with recipients=["keeper-c"]}];
  check bool "another caller cannot find this operation" true
    (D.find ledger ~caller:"foreign" ~operation_id:operation=Ok None);
  check bool "recipient acceptance before commit refused" true
    (D.recipient_result ledger ~caller:payload.caller ~operation_id:operation
      ~recipient:"keeper-a" D.Accepted=Error D.Conflict);
  let _committed=require (D.commit ledger ~caller:payload.caller ~operation_id:operation ~seq:7) in
  check bool "commit cannot change workspace sequence" true
    (D.commit ledger ~caller:payload.caller ~operation_id:operation ~seq:8=Error D.Conflict);
  let file=Sys.readdir root |> Array.to_list |> List.find (fun name -> Filename.check_suffix name ".jsonl") in
  let channel=open_out_gen [Open_append;Open_binary] 0o600 (Filename.concat root file) in
  output_string channel "{\"event\":\"invented\"}\n"; close_out channel;
  check bool "unknown stored state refuses recovery rather than consuming evidence" true
    (match recovery_failure (D.recover ledger) with Error (D.Corrupt _) -> true | _ -> false))
let test_pending_marker_crash_boundaries () = fixture (fun root ledger ->
  let _admitted=require (D.admit ledger payload) in
  let file=Sys.readdir root |> Array.to_list |> List.find (fun name -> Filename.check_suffix name ".jsonl") in
  let journal=Filename.concat root file in
  let marker=Filename.concat (Filename.concat root "pending") file in
  check bool "admitted intent has a recovery marker" true (Sys.file_exists marker);
  (* The marker became durable but no admitted event reached the journal. *)
  let channel=open_out_bin journal in close_out channel;
  check int "empty pre-admission crash marker is not an intention" 0
    (List.length (require (D.recover (D.create ~root))).pending);
  check bool "empty marker is retired" false (Sys.file_exists marker);
  let _admitted=require (D.admit ledger payload) in
  check int "retry after empty-marker cleanup is discoverable" 1
    (List.length (require (D.recover (D.create ~root))).pending);
  let original=Fs_compat.load_file journal |> Yojson.Safe.from_string in
  let fields=Yojson.Safe.Util.to_assoc original in
  List.iter (fun replacement ->
    let channel=open_out_bin journal in
    output_string channel (Yojson.Safe.to_string (`Assoc replacement) ^ "\n");close_out channel;
    check bool "unknown or missing sender authority never defaults" true
      (match recovery_failure (D.recover ledger) with Error (D.Corrupt _) -> true | _ -> false))
    [("sender_authority",`String "owner")::List.remove_assoc "sender_authority" fields;
     List.remove_assoc "sender_authority" fields])
let test_pending_journal_loss_and_invalid_identity () = fixture (fun root ledger ->
  ignore (require (D.admit ledger payload));
  let file=Sys.readdir root |> Array.to_list |> List.find (fun name -> Filename.check_suffix name ".jsonl") in
  let journal=Filename.concat root file in
  let marker=Filename.concat (Filename.concat root "pending") file in
  let original=Fs_compat.load_file journal in
  Sys.remove journal;
  check bool "missing pending evidence refuses recovery" true
    (match recovery_failure (D.recover ledger) with Error (D.Corrupt _) -> true | _ -> false);
  check bool "missing journal is never recreated" false (Sys.file_exists journal);
  check bool "missing evidence retains its durable marker" true (Sys.file_exists marker);
  let channel=open_out_bin journal in output_string channel "torn";close_out channel;
  check bool "torn pending evidence refuses recovery" true
    (match recovery_failure (D.recover ledger) with Error (D.Corrupt _) -> true | _ -> false);
  check string "torn evidence is unchanged" "torn" (Fs_compat.load_file journal);
  check bool "torn evidence retains its marker" true (Sys.file_exists marker);
  let channel=open_out_bin journal in output_string channel original;close_out channel;
  let invalid=Filename.concat (Filename.concat root "pending") "invalid.jsonl" in
  let channel=open_out_bin invalid in close_out channel;
  check bool "malformed pending identity refuses recovery" true
    (match recovery_failure (D.recover ledger) with Error (D.Corrupt _) -> true | _ -> false);
  check bool "malformed identity creates no journal" false
    (Sys.file_exists (Filename.concat root "invalid.jsonl"));
  check bool "invalid marker remains auditable" true (Sys.file_exists invalid);
  Sys.remove invalid;
  check int "restored authoritative journal resumes exact obligation" 1
    (List.length (require (D.recover ledger)).pending))
let test_existing_update_boundaries () = fixture (fun root _ ->
  let missing=Filename.concat (Filename.concat root "absent") "journal.jsonl" in
  let called=ref false in
  let decide bytes=called:=true;Some "suffix",bytes in
  check bool "existing-only missing result is typed" true
    (match Fs_compat.update_existing_private_file_durable_locked_result missing decide with
     | Fs_compat.Private_file_succeeded None -> true | _ -> false);
  check bool "missing never invokes callback" false !called;
  check bool "missing never creates parent" false (Sys.file_exists (Filename.dirname missing));
  let fifo=Filename.concat root "fifo" in Unix.mkfifo fifo 0o600;
  check bool "FIFO refused before reading or invoking callback" true
    (match Fs_compat.update_existing_private_file_durable_locked_result fifo decide with
     | Fs_compat.Private_file_failed (Fs_compat.Unexpected_transaction_file_kind Unix.S_FIFO) -> true
     | _ -> false);
  check bool "FIFO never invokes callback" false !called;
  let journal=Filename.concat root "regular" in
  let channel=open_out_bin journal in output_string channel "original";close_out channel;
  let alias=Filename.concat root "alias" in Unix.symlink journal alias;
  check bool "symlink refused" true
    (match Fs_compat.update_existing_private_file_durable_locked_result alias decide with
     | Fs_compat.Private_file_failed (Fs_compat.Unexpected_transaction_file_kind Unix.S_LNK) -> true
     | _ -> false);
  Sys.remove alias;
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent=(fun _ -> ());
    close_fd=(fun fd -> Unix.close fd;raise (Sys_error "fixture close failed"))} in
  check bool "semantic refusal and cleanup remain distinct" true
    (match Fs_compat.update_existing_private_file_durable_locked_with_io_for_testing ~io journal
       (fun bytes -> None,Error bytes) with
     | Fs_compat.Private_file_succeeded_with_cleanup_failure {value=Some (Error "original");_} -> true
     | _ -> false);
  check string "read-only semantic refusal changes no bytes" "original" (Fs_compat.load_file journal))
let test_status_misses_do_not_persist () = fixture (fun root ledger ->
  let missing_root=Filename.concat root "not-created" in
  let missing=D.create ~root:missing_root in
  check bool "missing directory is a missing operation" true
    (D.find missing ~caller:payload.caller ~operation_id:operation=Ok None);
  check bool "lookup does not create directory" false (Sys.file_exists missing_root);
  let admitted=require (D.admit ledger payload) in
  let before=Sys.readdir root |> Array.to_list |> List.sort String.compare in
  List.iter (fun id ->
    let operation_id=require (D.Request_id.of_string id) in
    check bool "unknown status is absent" true
      (D.find ledger ~caller:payload.caller ~operation_id=Ok None))
    ["never-admitted-1";"never-admitted-2";"never-admitted-3"];
  check (list string) "misses add no journal or lock files" before
    (Sys.readdir root |> Array.to_list |> List.sort String.compare);
  check bool "admitted record is readable" true
    (D.find ledger ~caller:payload.caller ~operation_id:operation=Ok (Some admitted));
  let file=Filename.concat root (List.hd before) in
  let channel=open_out_gen [Open_append;Open_binary] 0o600 file in
  output_string channel "torn"; close_out channel;
  check bool "torn tail remains a corruption, not a successful prefix" true
    (match D.find ledger ~caller:payload.caller ~operation_id:operation with
     | Error (D.Corrupt _) -> true | _ -> false))
let test_primary_and_settlement_are_preserved () = fixture (fun root ledger ->
  let _admitted=require (D.admit ledger payload) in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent=(fun _ -> ());
    close_fd=(fun fd -> Unix.close fd; raise (Sys_error "fixture close settlement failed"))} in
  let faulty=D.For_testing.create ~root ~io in
  check bool "status keeps a successful read and its close failure" true
    (match D.find faulty ~caller:payload.caller ~operation_id:operation with
     | Ok (Some {settlement_error=Some _;_}) -> true | _ -> false);
  check bool "primary collision survives descriptor cleanup failure" true
    (match D.admit faulty {payload with content="different"} with
     | Error (D.Settlement_failed {primary=D.Conflict;cleanup}) -> cleanup<>""
     | _ -> false);
  let _committed=require (D.commit ledger ~caller:payload.caller ~operation_id:operation ~seq:7) in
  check bool "existing-only commit preserves acknowledged close failure" true
    (match D.commit faulty ~caller:payload.caller ~operation_id:operation ~seq:7 with
     | Ok {record;settlement_error=Some _} -> record.workspace=D.Committed 7
     | _ -> false);
  check bool "existing-only contradictory commit retains semantic and close failures" true
    (match D.commit faulty ~caller:payload.caller ~operation_id:operation ~seq:8 with
     | Error (D.Settlement_failed {primary=D.Conflict;cleanup}) -> cleanup<>""
     | _ -> false);
  check bool "existing-only recipient mutation retains semantic and close failures" true
    (match D.recipient_result faulty ~caller:payload.caller ~operation_id:operation
       ~recipient:"not-admitted" D.Accepted with
     | Error (D.Settlement_failed {primary=D.Conflict;cleanup}) -> cleanup<>""
     | _ -> false);
  List.iter (fun recipient -> ignore (require (D.recipient_result ledger
    ~caller:payload.caller ~operation_id:operation ~recipient D.Accepted))) payload.recipients;
  let file=Sys.readdir root |> Array.to_list |> List.find (fun name -> Filename.check_suffix name ".jsonl") in
  let marker=Filename.concat (Filename.concat root "pending") file in
  check bool "terminal commit removes the pending index entry" false (Sys.file_exists marker);
  let closed=ref 0 in
  let counted=D.For_testing.create ~root ~io:{io with close_fd=(fun fd -> incr closed;Unix.close fd)} in
  ignore (require (D.recover counted));
  check int "idle recovery never opens completed audit journals" 0 !closed;
  (* Simulate a crash after terminal commit but before index retirement. *)
  let restore_marker ()=let channel=open_out_bin marker in close_out channel in
  restore_marker ();
  let recovered=require (D.recover faulty) in
  check int "cleanup problem never requeues completed projection" 0 (List.length recovered.pending);
  check int "settled record retains cleanup evidence" 1 (List.length recovered.settled_with_cleanup);
  let record=List.hd recovered.settled_with_cleanup in
  check bool "completed identity remains acknowledged despite cleanup failure" true
    (D.complete record.record && Option.is_some record.settlement_error);
  let file=Sys.readdir root |> Array.to_list |> List.find (fun name -> Filename.check_suffix name ".jsonl") in
  let channel=open_out_gen [Open_append;Open_binary] 0o600 (Filename.concat root file) in
  output_string channel "{\"event\":\"invented\"}\n"; close_out channel;
  restore_marker ();
  check bool "corrupt recovery state and settlement failure are both preserved" true
    (match recovery_failure (D.recover faulty) with
     | Error (D.Settlement_failed {primary=D.Corrupt _;cleanup}) -> cleanup<>""
     | _ -> false);
  check bool "existing-only mutations retain corrupt state and descriptor failure" true
    (match D.commit faulty ~caller:payload.caller ~operation_id:operation ~seq:7 with
     | Error (D.Settlement_failed {primary=D.Corrupt _;cleanup}) -> cleanup<>""
     | _ -> false);
  let channel=open_out_bin (Filename.concat root file) in
  output_string channel "{\n"; close_out channel;
  check bool "malformed JSON and descriptor failure remain typed recovery evidence" true
    (match recovery_failure (D.recover faulty) with
     | Error (D.Settlement_failed {primary=D.Corrupt _;cleanup}) -> cleanup<>""
     | _ -> false))
let test_unknown_mutations_do_not_persist () = fixture (fun root ledger ->
  let check_unknown ledger operation_id =
    check bool "unknown commit is refused" true
      (D.commit ledger ~caller:payload.caller ~operation_id ~seq:7=Error D.Unknown_operation);
    check bool "unknown recipient mutation is refused" true
      (D.recipient_result ledger ~caller:payload.caller ~operation_id
         ~recipient:"keeper-a" D.Accepted=Error D.Unknown_operation) in
  let missing_root=Filename.concat root "not-created" in
  check_unknown (D.create ~root:missing_root) operation;
  check bool "unknown mutations create no directory" false (Sys.file_exists missing_root);
  ignore (require (D.admit ledger payload));
  let before=Sys.readdir root |> Array.to_list |> List.sort String.compare in
  List.iter (fun id -> check_unknown ledger (require (D.Request_id.of_string id)))
    ["unknown-mutation-1";"unknown-mutation-2"];
  check (list string) "unknown mutations create no journals or locks" before
    (Sys.readdir root |> Array.to_list |> List.sort String.compare);
  check bool "admitted operation is readable before disappearance" true
    (match D.find ledger ~caller:payload.caller ~operation_id:operation with
     | Ok (Some _) -> true | _ -> false);
  let journal=List.find (fun name -> Filename.check_suffix name ".jsonl") before in
  Unix.unlink (Filename.concat root journal);
  let after=Sys.readdir root |> Array.to_list |> List.sort String.compare in
  check_unknown ledger operation;
  check (list string) "mutation after successful lookup never recreates removed journal" after
    (Sys.readdir root |> Array.to_list |> List.sort String.compare))
let test_regular_descriptor_boundary () = fixture (fun root ledger ->
  let admitted=require (D.admit ledger payload) in
  let name=Sys.readdir root |> Array.to_list
    |> List.find (fun name -> Filename.check_suffix name ".jsonl") in
  let filename=Filename.concat root name in
  let preserved=filename ^ ".preserved" in
  Unix.rename filename preserved;
  Unix.symlink preserved filename;
  check bool "regular symlink preserves exact admitted receipt" true
    (D.find ledger ~caller:payload.caller ~operation_id:operation=Ok (Some admitted));
  Unix.unlink filename;
  Unix.mkdir filename 0o700;
  check bool "directory is a typed nonregular descriptor" true
    (match Fs_compat.read_private_jsonl_rows_locked_result filename with
     | Fs_compat.Private_file_failed (Fs_compat.Private_jsonl_rows.Non_regular_file Unix.S_DIR) -> true
     | _ -> false);
  check bool "ledger refuses directory rather than acknowledging absence" true
    (match D.find ledger ~caller:payload.caller ~operation_id:operation with
     | Error (D.Io_error _) -> true | _ -> false);
  check bool "recovery refuses a directory journal without replacing it" true
    (match recovery_failure (D.recover ledger) with Error (D.Io_error _) -> true | _ -> false);
  check bool "directory journal remains a directory" true
    ((Unix.lstat filename).Unix.st_kind=Unix.S_DIR);
  Unix.rmdir filename;
  Unix.mkfifo filename 0o600;
  (* No writer is ever opened. A fixture child alarm bounds a regressed blocking
     open without imposing any timeout on the product reader. *)
  let pid=Unix.fork () in
  if pid=0 then (
    Sys.set_signal Sys.sigalrm Sys.Signal_default;
    ignore (Unix.alarm 5);
    try
      check bool "writerless FIFO is a typed nonregular descriptor" true
        (match Fs_compat.read_private_jsonl_rows_locked_result filename with
         | Fs_compat.Private_file_failed (Fs_compat.Private_jsonl_rows.Non_regular_file Unix.S_FIFO) -> true
         | _ -> false);
      check bool "ledger refuses writerless FIFO without waiting" true
        (match D.find ledger ~caller:payload.caller ~operation_id:operation with
         | Error (D.Io_error _) -> true | _ -> false);
      check bool "restart recovery refuses writerless FIFO without waiting" true
        (match recovery_failure (D.recover ledger) with Error (D.Io_error _) -> true | _ -> false);
      let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
        before_sync_parent=(fun _ -> ());
        close_fd=(fun fd -> Unix.close fd; raise (Sys_error "fixture nonregular close failure"))} in
      check bool "descriptor kind and close failure both survive" true
        (match Fs_compat.read_private_jsonl_rows_locked_with_io_for_testing ~io filename with
         | Fs_compat.Private_file_failed_with_cleanup_failure
             {error=Fs_compat.Private_jsonl_rows.Non_regular_file Unix.S_FIFO;cleanup_failure} ->
           Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure<>""
         | _ -> false);
      check bool "ledger retains primary refusal and cleanup failure" true
        (match D.find (D.For_testing.create ~root ~io)
           ~caller:payload.caller ~operation_id:operation with
         | Error (D.Settlement_failed {primary=D.Io_error _;cleanup}) -> cleanup<>""
         | _ -> false);
      exit 0
    with exn -> prerr_endline (Printexc.to_string exn); exit 1);
  let _,status=Unix.waitpid [] pid in
  check bool "FIFO child finishes successfully without a writer" true (status=Unix.WEXITED 0);
  check bool "refused FIFO remains unchanged" true ((Unix.lstat filename).Unix.st_kind=Unix.S_FIFO);
  Unix.unlink filename;
  Unix.rename preserved filename;
  check bool "refusals preserve original journal bytes and receipt" true
    (D.find ledger ~caller:payload.caller ~operation_id:operation=Ok (Some admitted)))
let test_recovery_disappearance_and_torn_journal () = fixture (fun root ledger ->
  ignore (require (D.admit ledger payload));
  let filename=Sys.readdir root |> Array.to_list
    |> List.find (fun name -> Filename.check_suffix name ".jsonl")
    |> Filename.concat root in
  let preserved=filename ^ ".preserved" in
  check bool "disappearance after scan refuses authoritative recovery" true
    (match recovery_failure (D.For_testing.recover ledger
       ~after_scan:(fun () -> Unix.rename filename preserved)) with
     | Error (D.Corrupt _) -> true | _ -> false);
  check bool "recovery does not recreate the disappeared journal" false (Sys.file_exists filename);
  Unix.rename preserved filename;
  let channel=open_out_gen [Open_append;Open_binary] 0o600 filename in
  output_string channel "torn"; close_out channel;
  let before=Fs_compat.load_file filename in
  check bool "torn journal refuses recovery without accepting its valid prefix" true
    (match recovery_failure (D.recover ledger) with Error (D.Corrupt _) -> true | _ -> false);
  check string "torn recovery evidence remains exact" before (Fs_compat.load_file filename))
let test_corrupt_journal_does_not_block_other_operations () = fixture (fun root ledger ->
  ignore (require (D.admit ledger payload));
  let bad = Sys.readdir root |> Array.to_list
    |> List.find (fun name -> Filename.check_suffix name ".jsonl") in
  let bad_path=Filename.concat root bad in
  let before=Fs_compat.load_file bad_path ^ "{" in
  Out_channel.with_open_bin bad_path (fun out -> output_string out before);
  let healthy={payload with operation_id=require (D.Request_id.of_string "healthy-operation")} in
  ignore (require (D.admit ledger healthy));
  let recovered=require (D.recover ledger) in
  check int "healthy operation remains recoverable" 1 (List.length recovered.pending);
  check bool "healthy identity is retained exactly" true
    (D.Request_id.equal (List.hd recovered.pending).record.payload.operation_id healthy.operation_id);
  check bool "damaged operation has explicit rejection evidence" true
    (match recovered.rejected with [(name,D.Corrupt _)] -> name=bad | _ -> false);
  check string "damaged evidence is preserved for operator repair" before (Fs_compat.load_file bad_path);
  check bool "damaged pending marker remains durable" true
    (Sys.file_exists (Filename.concat (Filename.concat root "pending") bad)))

let () = run "Durable optional Lane Broadcast intentions" ["recovery",[
  test_case "one damaged journal cannot block healthy deliveries" `Quick test_corrupt_journal_does_not_block_other_operations;
  test_case "recovery disappearance and torn evidence" `Quick test_recovery_disappearance_and_torn_journal;
  test_case "missing and invalid pending journals preserve evidence" `Quick test_pending_journal_loss_and_invalid_identity;
  test_case "existing-only transaction typed boundaries" `Quick test_existing_update_boundaries;
  test_case "pending index crash boundaries and strict authority" `Quick test_pending_marker_crash_boundaries;
  test_case "unknown mutations leave no durable files" `Quick test_unknown_mutations_do_not_persist;
  test_case "regular descriptor and writerless FIFO boundary" `Quick test_regular_descriptor_boundary;
  test_case "status misses leave no durable files" `Quick test_status_misses_do_not_persist;
  test_case "primary and descriptor settlement outcomes" `Quick test_primary_and_settlement_are_preserved;
  test_case "reopened commit and partial recipient obligations" `Quick test_restart_and_partial_fanout;
  test_case "operation collisions and invalid recovery state" `Quick test_collision_and_unknown_states]]
