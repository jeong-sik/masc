open Alcotest

module Id = Keeper_operation_id
module Request = Keeper_operation_request
module Blob = Keeper_operation_blob_store
module Mailbox = Keeper_operation_mailbox
module Store = Keeper_operation_store

let result_exn to_string = function
  | Ok value -> value
  | Error error -> fail (to_string error)
;;

let json_exn json =
  result_exn Request.Canonical_json.error_to_string
    (Request.Canonical_json.of_yojson json)
;;

let operation_id char =
  result_exn Fun.id (Id.Operation_id.of_string ("kop1:" ^ String.make 64 char))
;;

let request_exn ~operation_id ~request_id content =
  result_exn Fun.id
    (Request.make
       ~operation_id
       ~kind:Request.Message
       ~source_ref:(Request.Source_ref.Operator_message { request_id })
       ~submitter_ref:(Request.Submitter_ref.Operator { principal_id = "operator-1" })
       ~input:
         (json_exn
            (`Assoc
               [ "schema", `String "masc.keeper_operation.message_input.v1"
               ; "content", `String content
               ])))
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun entry -> remove_tree (Filename.concat path entry));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_dir f =
  let base_path = Filename.temp_dir "keeper-operation-ledger-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let test_strict_identifiers () =
  let valid = "kop1:" ^ String.make 64 'a' in
  check bool "valid operation id" true (Result.is_ok (Id.Operation_id.of_string valid));
  check bool
    "old operation id rejected"
    true
    (Result.is_error (Id.Operation_id.of_string ("kmsg1-" ^ String.make 64 'a')));
  check bool
    "uppercase digest rejected"
    true
    (Result.is_error
       (Id.Operation_id.of_string ("kop1:" ^ String.make 64 'A')));
  let parent = operation_id 'b' in
  let left =
    Id.Operation_id.for_keeper_message
      ~causing_operation:parent
      ~tool_call_id:"call-1"
      ~ordinal:1
      ~target_keeper:"ab"
  in
  let right =
    Id.Operation_id.for_keeper_message
      ~causing_operation:parent
      ~tool_call_id:"call-1"
      ~ordinal:11
      ~target_keeper:"b"
  in
  check bool
    "framed identity derivation"
    false
    (Id.Operation_id.equal left right)
  ;
  let another_call =
    Id.Operation_id.for_keeper_message
      ~causing_operation:parent
      ~tool_call_id:"call-2"
      ~ordinal:1
      ~target_keeper:"ab"
  in
  check bool "tool call identity participates in dedupe" false (Id.Operation_id.equal left another_call)
;;

let test_canonical_json_rejections () =
  check bool
    "duplicate fields rejected"
    true
    (Result.is_error
       (Request.Canonical_json.of_yojson
          (`Assoc [ "a", `Int 1; "a", `Int 2 ])));
  check bool
    "non-finite rejected"
    true
    (Result.is_error (Request.Canonical_json.of_yojson (`Float Float.nan)));
  check bool
    "invalid integer literal rejected"
    true
    (Result.is_error (Request.Canonical_json.of_yojson (`Intlit "01")));
  check bool
    "invalid UTF-8 rejected"
    true
    (Result.is_error
       (Request.Canonical_json.of_yojson (`String (String.make 1 '\xff'))));
  let first =
    json_exn (`Assoc [ "z", `Int 1; "a", `Assoc [ "b", `Int 2; "a", `Int 3 ] ])
  in
  let second =
    json_exn (`Assoc [ "a", `Assoc [ "a", `Int 3; "b", `Int 2 ]; "z", `Int 1 ])
  in
  check string
    "object fields canonicalized"
    (Request.Canonical_json.to_bytes first)
    (Request.Canonical_json.to_bytes second)
;;

let test_blob_store_kind_and_readback () =
  with_temp_dir @@ fun base_path ->
  let keeper_runtime_dir =
    Filename.concat base_path ".masc/keepers/sangsu"
  in
  let store = Blob.create ~base_path ~keeper_runtime_dir in
  let payload = json_exn (`Assoc [ "content", `String "hello" ]) in
  let input_ref = result_exn Blob.error_to_string (Blob.put_input store payload) in
  let fetched = result_exn Blob.error_to_string (Blob.fetch_input store input_ref) in
  let fetched = Option.get fetched in
  check string
    "exact blob payload"
    (Request.Canonical_json.to_bytes payload)
    (Request.Canonical_json.to_bytes fetched);
  let outcome = json_exn (`Assoc [ "kind", `String "accepted" ]) in
  let outcome_ref =
    result_exn Blob.error_to_string (Blob.put_outcome store outcome)
  in
  let fetched_outcome =
    result_exn Blob.error_to_string (Blob.fetch_outcome store outcome_ref)
    |> Option.get
  in
  check string
    "exact outcome payload"
    (Request.Canonical_json.to_bytes outcome)
    (Request.Canonical_json.to_bytes fetched_outcome);
  let state_ref =
    result_exn Fun.id
      (Blob.State_ref.of_string (Blob.Input_ref.to_string input_ref))
  in
  match Blob.fetch_state store state_ref with
  | Error (Blob.Kind_mismatch { expected = "state"; actual = "input" }) -> ()
  | Error error -> fail (Blob.error_to_string error)
  | Ok _ -> fail "typed blob kind mismatch was accepted"
;;

let with_store base_path f =
  let keeper_runtime_dir =
    Filename.concat base_path ".masc/keepers/sangsu"
  in
  let blobs = Blob.create ~base_path ~keeper_runtime_dir in
  let store =
    result_exn Store.error_to_string
      (Store.open_or_create ~base_path ~keeper_runtime_dir)
  in
  Fun.protect
    ~finally:(fun () -> ignore (Store.close store))
    (fun () -> f blobs store)
;;

let put_input blobs request =
  result_exn Blob.error_to_string (Blob.put_input blobs (Request.input request))
;;

let put_outcome blobs label =
  result_exn Blob.error_to_string
    (Blob.put_outcome blobs (json_exn (`Assoc [ "kind", `String label ])))
;;

let put_state blobs content =
  result_exn Blob.error_to_string
    (Blob.put_state blobs (json_exn (`Assoc [ "conversation", `String content ])))
;;

let admitted_operation = function
  | Store.Accepted operation | Store.Replayed operation -> operation
;;

let test_ledger_replay_fifo_and_terminal_immutability () =
  with_temp_dir @@ fun base_path ->
  with_store base_path @@ fun blobs store ->
  let first_id = operation_id '1' in
  let first = request_exn ~operation_id:first_id ~request_id:"req-1" "first" in
  let first_input = put_input blobs first in
  let accepted =
    result_exn Store.error_to_string
      (Store.admit store ~now:1. ~request:first ~input_ref:first_input)
  in
  (match accepted with
   | Store.Accepted operation -> check int64 "first sequence" 1L operation.queue_seq
   | Store.Replayed _ -> fail "new operation was reported as replay");
  (match
     result_exn Store.error_to_string
       (Store.admit store ~now:2. ~request:first ~input_ref:first_input)
   with
   | Store.Replayed _ -> ()
   | Store.Accepted _ -> fail "exact request replay inserted a second row");
  let conflicting = request_exn ~operation_id:first_id ~request_id:"req-1" "changed" in
  let conflicting_input = put_input blobs conflicting in
  (match Store.admit store ~now:3. ~request:conflicting ~input_ref:conflicting_input with
   | Error (Store.Identity_conflict operation_id) ->
     check string
       "conflicting id"
       (Id.Operation_id.to_string first_id)
       (Id.Operation_id.to_string operation_id)
   | Error error -> fail (Store.error_to_string error)
   | Ok _ -> fail "same id with different request digest was accepted");
  let second_id = operation_id '2' in
  let second = request_exn ~operation_id:second_id ~request_id:"req-2" "second" in
  let second_input = put_input blobs second in
  ignore
    (result_exn Store.error_to_string
       (Store.admit store ~now:4. ~request:second ~input_ref:second_input));
  let running =
    result_exn Store.error_to_string
      (Store.start_next store ~now:5. ~base_state_ref:None)
    |> Option.get
  in
  check string
    "FIFO starts first"
    (Id.Operation_id.to_string first_id)
    (Id.Operation_id.to_string running.operation_id);
  check bool
    "second start suppressed while Running"
    true
    (Option.is_none
       (result_exn Store.error_to_string
          (Store.start_next store ~now:6. ~base_state_ref:None)));
  let outcome = put_outcome blobs "succeeded" in
  let next_state = put_state blobs "first absorbed" in
  let settled =
    result_exn Store.error_to_string
      (Store.settle
         store
         ~now:7.
         ~operation_id:first_id
         ~outcome_ref:outcome
         ~next_state_ref:(Some next_state))
  in
  (match settled.state with
   | Store.Settled -> ()
   | _ -> fail "Running operation did not settle");
  let raw_db =
    Sqlite3.db_open
      (Filename.concat base_path ".masc/keepers/sangsu/operations.sqlite3")
  in
  let direct_update =
    Sqlite3.exec
      raw_db
      "UPDATE operations SET request_digest = lower(hex(randomblob(32))) WHERE state = 'settled'"
  in
  ignore (Sqlite3.db_close raw_db : bool);
  check bool "SQL trigger protects terminal row" true (direct_update <> Sqlite3.Rc.OK);
  let conflicting_outcome = put_outcome blobs "different" in
  (match
     Store.settle
       store
       ~now:8.
       ~operation_id:first_id
       ~outcome_ref:conflicting_outcome
       ~next_state_ref:(Some next_state)
   with
   | Error (Store.State_conflict _) -> ()
   | Error error -> fail (Store.error_to_string error)
   | Ok _ -> fail "terminal operation was reopened or overwritten");
  let second_running =
    result_exn Store.error_to_string
      (Store.start_next store ~now:9. ~base_state_ref:(Some next_state))
    |> Option.get
  in
  check string
    "second starts after settlement"
    (Id.Operation_id.to_string second_id)
    (Id.Operation_id.to_string second_running.operation_id);
  let interrupted = put_outcome blobs "process_crash" in
  let terminal =
    result_exn Store.error_to_string
      (Store.interrupt_running
         store
         ~now:10.
         ~operation_id:second_id
         ~evidence_ref:interrupted)
  in
  (match terminal.state with
   | Store.Interrupted -> ()
   | _ -> fail "Running operation did not become Interrupted");
  check int64
    "dedupe rows retained"
    2L
    (result_exn Store.error_to_string (Store.count_operations store))
;;

let test_cancel_and_pause () =
  with_temp_dir @@ fun base_path ->
  with_store base_path @@ fun blobs store ->
  check bool "fresh unpaused" false (result_exn Store.error_to_string (Store.paused store));
  result_exn Store.error_to_string (Store.set_paused store true);
  check bool "paused persisted" true (result_exn Store.error_to_string (Store.paused store));
  let operation_id = operation_id '3' in
  let request = request_exn ~operation_id ~request_id:"req-3" "cancel me" in
  let input_ref = put_input blobs request in
  ignore
    (admitted_operation
       (result_exn Store.error_to_string
          (Store.admit store ~now:1. ~request ~input_ref)));
  let cancelled =
    result_exn Store.error_to_string (Store.cancel_queued store ~now:2. operation_id)
  in
  (match cancelled.state with
   | Store.Cancelled -> ()
   | _ -> fail "Queued operation did not cancel");
  let replay =
    result_exn Store.error_to_string (Store.cancel_queued store ~now:3. operation_id)
  in
  check int64 "cancel replay same row" cancelled.queue_seq replay.queue_seq
;;

let test_bounded_mailbox () =
  let mailbox = result_exn Fun.id (Mailbox.create ~capacity:2) in
  check int "capacity" 2 (Mailbox.capacity mailbox);
  check bool "open" false (Mailbox.is_closed mailbox);
  check bool "first added" true (Mailbox.try_add mailbox 1 = Mailbox.Added);
  check bool "second added" true (Mailbox.try_add mailbox 2 = Mailbox.Added);
  check int "full depth" 2 (Mailbox.length mailbox);
  check bool "full is immediate" true (Mailbox.try_add mailbox 3 = Mailbox.Full);
  Eio_main.run @@ fun _env ->
  check (option int) "FIFO first" (Some 1) (Mailbox.take mailbox);
  check (option int) "FIFO second" (Some 2) (Mailbox.take mailbox);
  Eio.Switch.run @@ fun sw ->
  let result, resolve = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve (Mailbox.take mailbox));
  Eio.Fiber.yield ();
  Mailbox.close mailbox;
  check (option int) "close wakes empty consumer" None (Eio.Promise.await result);
  check bool "closed" true (Mailbox.is_closed mailbox);
  check bool "closed rejects" true (Mailbox.try_add mailbox 4 = Mailbox.Closed)
;;

let () =
  run
    "keeper operation ledger"
    [ ( "identity"
      , [ test_case "strict identifiers" `Quick test_strict_identifiers
        ; test_case
            "canonical JSON rejection"
            `Quick
            test_canonical_json_rejections
        ] )
    ; ( "blob"
      , [ test_case
            "typed durable blob read-back"
            `Quick
            test_blob_store_kind_and_readback
        ] )
    ; ( "ledger"
      , [ test_case
            "replay FIFO terminal immutability"
            `Quick
            test_ledger_replay_fifo_and_terminal_immutability
        ; test_case "cancel and pause" `Quick test_cancel_and_pause
        ] )
    ; ( "mailbox"
      , [ test_case "bounded non-blocking admission" `Quick test_bounded_mailbox ] )
    ]
;;
