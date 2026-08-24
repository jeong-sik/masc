open Alcotest

module Operation = Keeper_chat_operation
module Store = Keeper_chat_operation_store
module Id = Operation.Operation_id

let store_ok = function
  | Ok value -> value
  | Error error -> fail (Store.error_to_string error)
;;

let id value =
  match Id.of_string value with
  | Ok value -> value
  | Error detail -> fail detail
;;

let source identity =
  `Assoc [ "kind", `String "dashboard"; "identity", `String identity ]
;;

let input text = `Assoc [ "text", `String text ]

let with_store name f =
  let directory = Filename.temp_dir ("keeper-chat-operations-" ^ name) "" in
  let path = Filename.concat directory Store.For_testing.database_file in
  let store = store_ok (Store.open_or_create ~path) in
  Fun.protect
    ~finally:(fun () -> ignore (Store.close store : (unit, Store.error) result))
    (fun () -> f path store)
;;

let accepted = function
  | Store.Accepted operation -> operation
  | Store.Existing _ -> fail "first submission unexpectedly replayed"
;;

let get_exn store operation_id =
  match store_ok (Store.get store operation_id) with
  | Some operation -> operation
  | None -> fail "operation disappeared"
;;

let state operation = Operation.state_to_string operation.Operation.state

let finalize_statement stmt =
  let rc = Sqlite3.finalize stmt in
  ignore (Sys.opaque_identity stmt);
  rc
;;

let close_database db =
  let closed = Sqlite3.db_close db in
  ignore (Sys.opaque_identity db);
  closed
;;

let test_schema_identity_and_budget () =
  with_store "schema" @@ fun path store ->
  check string "database file" "chat-operations.sqlite3" (Filename.basename path);
  check
    (list (pair string int))
    "two strict tables"
    [ "metadata", 3; "operations", 13 ]
    Store.For_testing.table_column_counts;
  store_ok (Store.close store);
  let db = Sqlite3.db_open ~mode:`READONLY path in
  Fun.protect
    ~finally:(fun () -> ignore (close_database db : bool))
    (fun () ->
       let text sql =
         let stmt = Sqlite3.prepare db sql in
         Fun.protect
           ~finally:(fun () -> ignore (finalize_statement stmt : Sqlite3.Rc.t))
           (fun () ->
              check bool "schema row" true (Sqlite3.step stmt = Sqlite3.Rc.ROW);
              Sqlite3.column_text stmt 0)
       in
       check
         string
         "schema identity"
         "masc.keeper_chat_operations.v1"
         (text "SELECT schema FROM metadata WHERE singleton = 1");
       check
         int64
         "application id"
         Store.For_testing.database_application_id
         (Int64.of_string (text "SELECT application_id FROM pragma_application_id")))
;;

let test_exact_idempotency_and_terminal_dedupe () =
  with_store "idempotency" @@ fun _path store ->
  let operation_id = id "kmsg-idempotency" in
  let original_source = source "operator" in
  let original_input = input "hello" in
  let first =
    Store.submit
      store
      ~now:1.0
      ~operation_id
      ~source:original_source
      ~input:original_input
    |> store_ok
    |> accepted
  in
  check
    string
    "wire projection keeps execution identity"
    first.execution_digest
    Yojson.Safe.Util.(Operation.to_json first |> member "execution_digest" |> to_string);
  (match
     store_ok
       (Store.submit
          store
          ~now:2.0
          ~operation_id
          ~source:original_source
          ~input:original_input)
   with
   | Store.Existing replayed ->
     check string "same identity" (Id.to_string first.operation_id) (Id.to_string replayed.operation_id)
   | Store.Accepted _ -> fail "same request was inserted twice");
  (match
     Store.submit
       store
       ~now:3.0
       ~operation_id
       ~source:original_source
       ~input:(input "different")
   with
   | Error (Store.Idempotency_conflict observed) ->
     check string "conflicting id" (Id.to_string operation_id) (Id.to_string observed)
   | Error error -> fail ("wrong conflict: " ^ Store.error_to_string error)
   | Ok _ -> fail "different request reused an operation id");
  (match
     Store.submit
       store
       ~now:3.5
       ~operation_id
       ~source:(source "different-actor")
       ~input:original_input
   with
   | Error (Store.Idempotency_conflict observed) ->
     check string "changed-source conflict" (Id.to_string operation_id) (Id.to_string observed)
   | Error error -> fail ("wrong source conflict: " ^ Store.error_to_string error)
   | Ok _ -> fail "different authorized actor reused an operation id");
  ignore (store_ok (Store.claim_next store ~now:4.0));
  let terminal =
    store_ok
      (Store.succeed_running
         store
         ~now:5.0
         ~operation_id
         ~outcome_ref:"transcript:terminal")
  in
  check string "succeeded" "succeeded" (state terminal);
  check bool "terminal input scrubbed" true (Option.is_none terminal.input);
  (match
     store_ok
       (Store.submit
          store
          ~now:6.0
          ~operation_id
          ~source:original_source
          ~input:original_input)
   with
   | Store.Existing replayed ->
     check string "terminal replay" "succeeded" (state replayed);
     check bool "replay stays scrubbed" true (Option.is_none replayed.input)
   | Store.Accepted _ -> fail "terminal operation dedupe expired")
;;

let test_fifo_edit_move_cancel () =
  with_store "fifo" @@ fun _path store ->
  let submit ordinal =
    let operation_id = id (Printf.sprintf "kmsg-fifo-%d" ordinal) in
    let operation =
      Store.submit
        store
        ~now:(float_of_int ordinal)
        ~operation_id
        ~source:(source "operator")
        ~input:(input (Printf.sprintf "message-%d" ordinal))
      |> store_ok
      |> accepted
    in
    operation_id, operation
  in
  let first_id, first = submit 1 in
  let second_id, second = submit 2 in
  let third_id, _third = submit 3 in
  let edited =
    store_ok (Store.edit_queued store ~operation_id:second_id ~input:(input "edited"))
  in
  check bool "admission digest stable after edit" true
    (String.equal second.admission_digest edited.admission_digest);
  check bool "execution digest changes after edit" false
    (String.equal second.execution_digest edited.execution_digest);
  let moved = store_ok (Store.move_queued_to_end store ~operation_id:first_id) in
  check bool "move allocates a later sequence" true
    (Int64.compare moved.sequence first.sequence > 0);
  let cancelled = store_ok (Store.cancel_queued store ~now:4.0 ~operation_id:third_id) in
  check string "cancelled" "cancelled" (state cancelled);
  check bool "cancel scrubbed input" true (Option.is_none cancelled.input);
  let queued = store_ok (Store.list_queued store ~after_sequence:None ~limit:10) in
  check
    (list string)
    "FIFO except explicit move"
    [ Id.to_string second_id; Id.to_string first_id ]
    (List.map (fun operation -> Id.to_string operation.Operation.operation_id) queued);
  let inventory = store_ok (Store.inventory store) in
  check int "queued projection" 2 inventory.queued_count;
  check int "terminal projection" 1 inventory.terminal_count;
  check bool "no running projection" true (Option.is_none inventory.running_operation_id);
  let running = Option.get (store_ok (Store.claim_next store ~now:5.0)) in
  check string "edited operation runs first" (Id.to_string second_id) (Id.to_string running.operation_id);
  let inventory = store_ok (Store.inventory store) in
  check int "queued after claim" 1 inventory.queued_count;
  check bool "running projection" true
    (Option.exists (Id.equal second_id) inventory.running_operation_id);
  (match Store.edit_queued store ~operation_id:second_id ~input:(input "late") with
   | Error (Store.Not_queued _) -> ()
   | Error error -> fail ("wrong edit race result: " ^ Store.error_to_string error)
   | Ok _ -> fail "running operation was edited")
;;

let test_restart_interrupts_running_once_and_preserves_queued () =
  with_store "restart" @@ fun path store ->
  let running_id = id "kmsg-restart-running" in
  let queued_id = id "kmsg-restart-queued" in
  let submit operation_id text now =
    Store.submit store ~now ~operation_id ~source:(source "operator") ~input:(input text)
    |> store_ok
    |> ignore
  in
  submit running_id "running" 1.0;
  submit queued_id "queued" 2.0;
  ignore (store_ok (Store.claim_next store ~now:3.0));
  store_ok (Store.close store);
  let reopened = store_ok (Store.open_or_create ~path) in
  Fun.protect
    ~finally:(fun () -> ignore (Store.close reopened : (unit, Store.error) result))
    (fun () ->
       check int "one running interrupted" 1
         (store_ok (Store.settle_running_after_restart reopened ~now:4.0));
       check int "settlement is idempotent" 0
         (store_ok (Store.settle_running_after_restart reopened ~now:5.0));
       let interrupted = get_exn reopened running_id in
       (match interrupted.state with
        | Operation.Failed
            { failure = { kind = Operation.Interrupted_by_restart; _ }; _ } -> ()
        | _ -> fail "running operation was not interrupted");
       check bool "interrupted input scrubbed" true (Option.is_none interrupted.input);
       let queued = get_exn reopened queued_id in
       check string "queued survives restart" "queued" (state queued);
       check bool "queued body survives" true (Option.is_some queued.input))
;;

let test_strict_json_rejects_duplicate_fields () =
  with_store "strict-json" @@ fun _path store ->
  let duplicate = `Assoc [ "text", `String "one"; "text", `String "two" ] in
  match
    Store.submit
      store
      ~now:1.0
      ~operation_id:(id "kmsg-duplicate")
      ~source:(source "operator")
      ~input:duplicate
  with
  | Error (Store.Invalid_input _) -> ()
  | Error error -> fail ("wrong strict JSON error: " ^ Store.error_to_string error)
  | Ok _ -> fail "duplicate JSON fields were accepted"
;;

let test_commit_failure_and_uncertain_readback () =
  with_store "commit-fault" @@ fun _path store ->
  let rejected_id = id "kmsg-before-commit" in
  Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
  (match
     Store.submit
       store
       ~now:1.0
       ~operation_id:rejected_id
       ~source:(source "operator")
       ~input:(input "not committed")
   with
   | Error (Store.Store_unavailable _) -> ()
   | Error error -> fail ("wrong pre-commit error: " ^ Store.error_to_string error)
   | Ok _ -> fail "pre-commit failure was acknowledged");
  check bool "pre-commit state unchanged" true
    (Option.is_none (store_ok (Store.get store rejected_id)));
  let uncertain_id = id "kmsg-after-commit" in
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  let accepted =
    Store.submit
      store
      ~now:2.0
      ~operation_id:uncertain_id
      ~source:(source "operator")
      ~input:(input "committed")
    |> store_ok
    |> accepted
  in
  check string "uncertain submit read-back" "queued" (state accepted);
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  let running = Option.get (store_ok (Store.claim_next store ~now:3.0)) in
  check string "uncertain running read-back" "running" (state running);
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  let terminal =
    store_ok
      (Store.succeed_running
         store
         ~now:4.0
         ~operation_id:uncertain_id
         ~outcome_ref:"transcript:uncertain")
  in
  check string "uncertain terminal read-back" "succeeded" (state terminal)
;;

let test_terminal_row_is_sql_immutable () =
  with_store "terminal-immutable" @@ fun path store ->
  let operation_id = id "kmsg-terminal-immutable" in
  ignore
    (store_ok
       (Store.submit
          store
          ~now:1.0
          ~operation_id
          ~source:(source "operator")
          ~input:(input "terminal")));
  ignore (store_ok (Store.claim_next store ~now:2.0));
  ignore
    (store_ok
       (Store.succeed_running
          store
          ~now:3.0
          ~operation_id
          ~outcome_ref:"transcript:immutable"));
  store_ok (Store.close store);
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () -> ignore (close_database db : bool))
    (fun () ->
       let rc =
         Sqlite3.exec
           db
           "UPDATE operations SET outcome_ref = 'rewritten' WHERE operation_id = 'kmsg-terminal-immutable'"
       in
       check bool "terminal update rejected" false (Sqlite3.Rc.is_success rc))
;;


(* [closed] is an [Atomic] so that the test-and-set in [close] is one step and
   exactly one caller reaches [Sqlite3.db_close]. Two things have to hold and
   neither was covered: a second close is a no-op that still reports success,
   and every operation after a close is refused rather than reaching the freed
   handle. *)
let test_close_is_idempotent_and_refuses_later_operations () =
  let directory = Filename.temp_dir "keeper-chat-operations-close" "" in
  let path = Filename.concat directory Store.For_testing.database_file in
  let store = store_ok (Store.open_or_create ~path) in
  store_ok (Store.close store);
  store_ok (Store.close store);
  let operation_id =
    match Operation.Operation_id.of_string "op-after-close" with
    | Ok id -> id
    | Error detail -> fail ("operation id fixture rejected: " ^ detail)
  in
  (match Store.get store operation_id with
   | Ok _ -> fail "get after close must be refused"
   | Error _ -> ());
  match Store.close store with
  | Ok () -> ()
  | Error _ -> fail "a repeated close must stay successful"
;;

let test_statement_finalize_survives_gc_pressure () =
  with_store "finalize-gc-pressure" @@ fun _path store ->
  let churn = ref [] in
  for i = 1 to 2_000 do
    ignore (store_ok (Store.inventory store));
    churn := String.make 256 'x' :: (if i mod 16 = 0 then [] else !churn);
    if i mod 64 = 0 then Gc.minor ()
  done;
  ignore (Sys.opaque_identity !churn);
  (* [check bool msg true] is a partial application: it is [bool -> unit], so
     this case had the type [unit -> bool -> unit] and never ran an assertion.
     The observable it was reaching for is that the store still answers after
     the churn — a statement finalized out from under it surfaces as a failing
     inventory, not as a silent one, so the read has to be taken and checked. *)
  check
    bool
    "inventory still answers after GC pressure"
    true
    (Result.is_ok (Store.inventory store))
;;

let () =
  run
    "keeper-chat-operation-store"
    [ ( "store"
      , [ test_case "schema identity and budget" `Quick test_schema_identity_and_budget
        ; test_case "close is idempotent and refuses later operations" `Quick
            test_close_is_idempotent_and_refuses_later_operations
        ; test_case "exact idempotency and terminal dedupe" `Quick
            test_exact_idempotency_and_terminal_dedupe
        ; test_case "FIFO edit move cancel" `Quick test_fifo_edit_move_cancel
        ; test_case "restart interruption" `Quick
            test_restart_interrupts_running_once_and_preserves_queued
        ; test_case "strict JSON" `Quick test_strict_json_rejects_duplicate_fields
        ; test_case "commit failure and uncertain read-back" `Quick
            test_commit_failure_and_uncertain_readback
        ; test_case "terminal SQL immutability" `Quick test_terminal_row_is_sql_immutable
        ; test_case "statement finalize survives GC pressure" `Quick
            test_statement_finalize_survives_gc_pressure
        ] )
    ]
