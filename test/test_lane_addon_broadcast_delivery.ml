open Alcotest
module D = Masc.Lane_addon_broadcast_delivery
let require = function Ok v -> v | Error _ -> fail "delivery ledger refused"
let rec remove path = if Sys.is_directory path then (
  Array.iter (fun child -> remove (Filename.concat path child)) (Sys.readdir path);
  Unix.rmdir path) else Sys.remove path
let fixture f =
  let root=Filename.temp_file "fleet-ledger" ".fixture" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root (D.create ~root))
let operation = require (D.Request_id.of_string "evidence-request-1")
let payload : D.payload = {caller="operator";operation_id=operation;
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
    [{payload with content="different"};{payload with artifact_sha256=String.make 64 'b'};
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
    (match D.recover ledger with Error (D.Corrupt _) -> true | _ -> false))
let test_primary_and_settlement_are_preserved () = fixture (fun root ledger ->
  let _admitted=require (D.admit ledger payload) in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing = {
    before_sync_parent=(fun _ -> ());
    close_fd=(fun fd -> Unix.close fd; raise (Sys_error "fixture close settlement failed"))} in
  let faulty=D.For_testing.create ~root ~io in
  check bool "primary collision survives descriptor cleanup failure" true
    (match D.admit faulty {payload with content="different"} with
     | Error (D.Settlement_failed {primary=D.Conflict;cleanup}) -> cleanup<>""
     | _ -> false);
  let _committed=require (D.commit ledger ~caller:payload.caller ~operation_id:operation ~seq:7) in
  List.iter (fun recipient -> ignore (require (D.recipient_result ledger
    ~caller:payload.caller ~operation_id:operation ~recipient D.Accepted))) payload.recipients;
  let recovered=require (D.recover faulty) in
  check int "cleanup problem never requeues completed projection" 0 (List.length recovered.pending);
  check int "settled record retains cleanup evidence" 1 (List.length recovered.settled_with_cleanup);
  let record=List.hd recovered.settled_with_cleanup in
  check bool "completed identity remains acknowledged despite cleanup failure" true
    (D.complete record.record && Option.is_some record.settlement_error);
  let file=Sys.readdir root |> Array.to_list |> List.find (fun name -> Filename.check_suffix name ".jsonl") in
  let channel=open_out_gen [Open_append;Open_binary] 0o600 (Filename.concat root file) in
  output_string channel "{\"event\":\"invented\"}\n"; close_out channel;
  check bool "corrupt recovery state and settlement failure are both preserved" true
    (match D.recover faulty with
     | Error (D.Settlement_failed {primary=D.Corrupt _;cleanup}) -> cleanup<>""
     | _ -> false);
  let channel=open_out_bin (Filename.concat root file) in
  output_string channel "{\n"; close_out channel;
  check bool "malformed JSON and descriptor failure remain typed recovery evidence" true
    (match D.recover faulty with
     | Error (D.Settlement_failed {primary=D.Corrupt _;cleanup}) -> cleanup<>""
     | _ -> false))
let () = run "Durable optional Lane Broadcast intentions" ["recovery",[
  test_case "primary and descriptor settlement outcomes" `Quick test_primary_and_settlement_are_preserved;
  test_case "reopened commit and partial recipient obligations" `Quick test_restart_and_partial_fanout;
  test_case "operation collisions and invalid recovery state" `Quick test_collision_and_unknown_states]]
