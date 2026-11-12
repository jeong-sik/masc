(** The receipt-wait transition table, driven against the real store.

    [Keeper_receipt_wait_state.step] writes every task and event pair. Each
    test case below builds a task in the pair's state in a fresh store, applies
    the event through the store function the table names, and compares what
    the store did with the table. A refused event must also leave the task
    where it was. *)

open Alcotest
module Store = Keeper_chat_operation_store
module Execution = Keeper_semantic_execution
module Wait = Keeper_receipt_wait_state
module Chat = Keeper_chat_operation
module Scope = Keeper_execution_scope_id

let store_ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let semantic_ok = function Ok value -> value | Error error -> fail (Store.semantic_error_to_string error)
let string_ok = function Ok value -> value | Error detail -> fail detail

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_store f =
  let directory = Filename.temp_dir "keeper-receipt-wait-" "" in
  let store =
    Store.open_or_create ~path:(Filename.concat directory Store.database_file) |> store_ok
  in
  Fun.protect
    ~finally:(fun () ->
      Store.close store |> store_ok;
      remove_tree directory)
    (fun () -> f store)
;;

let awaited = "request-awaited"
let other_request = "request-other"

let obligation request_id state =
  Execution.receipt_obligation ~request_id ~state |> string_ok
;;

let checkpoint () =
  let trace_id = Keeper_id.Trace_id.of_string "receipt-wait-trace" |> string_ok in
  match
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~turn_count:3
      ~sha256:(Keeper_checkpoint_ref.sha256_of_canonical_bytes "checkpoint bytes")
  with
  | Ok reference -> reference
  | Error _ -> fail "checkpoint fixture rejected"
;;

let operation_id name = Chat.Operation_id.of_string name |> string_ok
let input = `Assoc [ "kind", `String "test_turn"; "message", `String "wait for a request" ]

let submit store ~now name =
  ignore
    (Store.submit
       store
       ~now
       ~operation_id:(operation_id name)
       ~source:(`Assoc [ "kind", `String "direct" ])
       ~input
     |> store_ok)
;;

let claim store ~now =
  match Store.claim_next store ~now |> store_ok with
  | Some operation -> operation
  | None -> fail "no operation was claimable"
;;

let defer store ~now (operation : Chat.t) request_id state =
  Store.defer_direct_checkpoint
    ~receipt_wait:(obligation request_id state)
    store
    ~now
    ~operation_id:operation.operation_id
    ~execution_digest:operation.execution_digest
    ~checkpoint:(Execution.Agent_core (checkpoint ()))
;;

let current_task store (operation : Chat.t) =
  let row =
    match Store.get store operation.operation_id |> store_ok with
    | Some row -> row
    | None -> fail "the operation disappeared"
  in
  let obligations =
    match Store.semantic_get store (Scope.direct_operation operation.operation_id) |> semantic_ok with
    | Some execution -> execution.receipt_obligations
    | None -> []
  in
  Wait.task row.state (Wait.awaiting obligations)
;;

(* The task under test is the only operation in the store. *)
let build store task =
  submit store ~now:1. "target";
  let target = Option.get (Store.get store (operation_id "target") |> store_ok) in
  match (task : Wait.task) with
  | Wait.Queued -> target
  | Wait.Cancelled ->
    ignore (Store.cancel_queued store ~now:2. ~operation_id:target.operation_id |> store_ok);
    target
  | Wait.Running ->
    ignore (claim store ~now:2.);
    target
  | Wait.Succeeded ->
    ignore (claim store ~now:2.);
    ignore
      (Store.succeed_running store ~now:3. ~operation_id:target.operation_id ~outcome_ref:"done"
       |> store_ok);
    target
  | Wait.Failed ->
    ignore (claim store ~now:2.);
    ignore
      (Store.fail_running
         store
         ~now:3.
         ~operation_id:target.operation_id
         ~kind:Chat.Turn_exception
         ~detail:"the turn failed"
         ~outcome_ref:None
       |> store_ok);
    target
  | Wait.Waiting ->
    let claimed = claim store ~now:2. in
    ignore (defer store ~now:3. claimed awaited Execution.Pending |> store_ok);
    target
  | Wait.Ready ->
    let claimed = claim store ~now:2. in
    ignore
      (defer store ~now:3. claimed awaited (Execution.Arrived Execution.Receipt_in_outbox)
       |> store_ok);
    target
;;

type answer =
  | Accepted
  | Refused

(* Applies [event] to [target] through the store function the table names. *)
let apply store (target : Chat.t) event =
  match (event : Wait.event) with
  | Wait.Claim ->
    (match Store.claim_next store ~now:10. |> store_ok with
     | Some _ -> Accepted
     | None -> Refused)
  | Wait.Wait presence ->
    let state =
      match presence with
      | Wait.Receipt_written -> Execution.Arrived Execution.Receipt_in_outbox
      | Wait.Receipt_not_written -> Execution.Pending
    in
    (* A different request, so the call is a new Wait and not the repeat of the
       earlier commit that the store confirms. *)
    (match defer store ~now:10. target other_request state with
     | Ok _ -> Accepted
     | Error _ -> Refused)
  | Wait.Resolve ->
    ignore
      (Store.resolve_receipt
         store
         ~now:10.
         ~request_id:awaited
         ~resolution:Execution.Receipt_in_outbox
       |> store_ok);
    Accepted
  | Wait.Complete ->
    (match
       Store.succeed_running store ~now:10. ~operation_id:target.operation_id ~outcome_ref:"done"
     with
     | Ok _ -> Accepted
     | Error _ -> Refused)
  | Wait.Fail ->
    (match
       Store.fail_running
         store
         ~now:10.
         ~operation_id:target.operation_id
         ~kind:Chat.Turn_exception
         ~detail:"the turn failed"
         ~outcome_ref:None
     with
     | Ok _ -> Accepted
     | Error _ -> Refused)
  | Wait.Cancel ->
    (match Store.cancel_queued store ~now:10. ~operation_id:target.operation_id with
     | Ok _ -> Accepted
     | Error _ -> Refused)
  | Wait.Restart ->
    ignore
      (Store.settle_running_without_executor store ~cause:Store.After_process_restart ~now:10.
       |> store_ok);
    Accepted
;;

let outcome_to_string = function
  | Wait.Moves_to task -> "moves to " ^ Wait.task_to_string task
  | Wait.Stays -> "stays"
  | Wait.Rejected -> "rejected"
;;

let outcome = testable (fun fmt value -> Format.pp_print_string fmt (outcome_to_string value)) ( = )

let test_pair task event () =
  with_store (fun store ->
    let target = build store task in
    check
      string
      "the fixture is in the pair's state"
      (Wait.task_to_string task)
      (Wait.task_to_string (current_task store target));
    let answer = apply store target event in
    let after = current_task store target in
    let observed =
      match answer with
      | Refused ->
        check
          string
          "a refused event leaves the task where it was"
          (Wait.task_to_string task)
          (Wait.task_to_string after);
        Wait.Rejected
      | Accepted -> if after = task then Wait.Stays else Wait.Moves_to after
    in
    check outcome "the store does what the table says" (Wait.step task event) observed)
;;

(* The invariants of RFC 3.5, checked on the store rather than the table. *)

let test_one_request_has_one_owner () =
  with_store (fun store ->
    submit store ~now:1. "first";
    let first = claim store ~now:2. in
    ignore (defer store ~now:3. first awaited Execution.Pending |> store_ok);
    submit store ~now:4. "second";
    let second = claim store ~now:5. in
    (match defer store ~now:6. second awaited Execution.Pending with
     | Error _ -> ()
     | Ok _ -> fail "a request that another task owns was owned twice");
    check string "the second task still runs" "running" (Chat.state_to_string (Option.get (Store.get store second.operation_id |> store_ok)).state);
    check string "the first task still waits" "waiting" (Wait.task_to_string (current_task store first)))
;;

let test_a_waiting_task_is_not_claimed_while_another_runs () =
  with_store (fun store ->
    submit store ~now:1. "waiter";
    let waiter = claim store ~now:2. in
    ignore (defer store ~now:3. waiter awaited Execution.Pending |> store_ok);
    submit store ~now:4. "bystander";
    let claimed = claim store ~now:5. in
    check
      string
      "the waiting task is skipped, so the next one runs"
      "bystander"
      (Chat.Operation_id.to_string claimed.operation_id))
;;

let test_a_second_notice_does_not_pull_a_running_task_back () =
  with_store (fun store ->
    submit store ~now:1. "waiter";
    let waiter = claim store ~now:2. in
    ignore (defer store ~now:3. waiter awaited Execution.Pending |> store_ok);
    let first =
      Store.resolve_receipt store ~now:4. ~request_id:awaited ~resolution:Execution.Receipt_in_outbox
      |> store_ok
    in
    check bool "the first notice resolves it" true (first = Store.Receipt_resolved);
    ignore (claim store ~now:5.);
    check string "the task runs" "running" (Wait.task_to_string (current_task store waiter));
    let second =
      Store.resolve_receipt store ~now:6. ~request_id:awaited ~resolution:Execution.Receipt_in_outbox
      |> store_ok
    in
    check bool "the second notice finds it already arrived" true (second = Store.Receipt_already_arrived);
    check string "the task still runs" "running" (Wait.task_to_string (current_task store waiter)))
;;

let test_a_notice_for_an_unowned_request_changes_nothing () =
  with_store (fun store ->
    submit store ~now:1. "waiter";
    let waiter = claim store ~now:2. in
    ignore (defer store ~now:3. waiter awaited Execution.Pending |> store_ok);
    let answer =
      Store.resolve_receipt store ~now:4. ~request_id:other_request ~resolution:Execution.Receipt_in_outbox
      |> store_ok
    in
    check bool "nobody owns that request" true (answer = Store.Receipt_without_owner);
    check string "the waiting task keeps waiting" "waiting" (Wait.task_to_string (current_task store waiter)))
;;

let test_a_source_lost_notice_makes_the_task_ready_like_a_receipt () =
  with_store (fun store ->
    submit store ~now:1. "waiter";
    let waiter = claim store ~now:2. in
    ignore (defer store ~now:3. waiter awaited Execution.Pending |> store_ok);
    ignore
      (Store.resolve_receipt store ~now:4. ~request_id:awaited ~resolution:Execution.Source_lost
       |> store_ok);
    check string "the task is ready" "ready" (Wait.task_to_string (current_task store waiter));
    let execution =
      Option.get (Store.semantic_get store (Scope.direct_operation waiter.operation_id) |> semantic_ok)
    in
    check
      bool
      "the entry says the source was lost"
      true
      (List.map
         (fun (entry : Execution.receipt_obligation) -> entry.request_id, entry.state)
         execution.receipt_obligations
       = [ awaited, Execution.Arrived Execution.Source_lost ]))
;;

let test_waiting_again_on_a_received_request_does_not_wait () =
  with_store (fun store ->
    submit store ~now:1. "waiter";
    let waiter = claim store ~now:2. in
    ignore (defer store ~now:3. waiter awaited Execution.Pending |> store_ok);
    ignore
      (Store.resolve_receipt store ~now:4. ~request_id:awaited ~resolution:Execution.Receipt_in_outbox
       |> store_ok);
    ignore (claim store ~now:5.);
    ignore
      (Store.resume_direct_checkpoint
         store
         ~now:6.
         ~operation_id:waiter.operation_id
         ~observed:(Execution.Agent_core (checkpoint ()))
       |> store_ok);
    (* The resumed turn asks to wait for the same request again. The receipt is
       still in the outbox until a turn completes, so it is not pending. *)
    ignore (defer store ~now:7. waiter awaited Execution.Pending |> store_ok);
    check string "the task is ready, not waiting" "ready" (Wait.task_to_string (current_task store waiter));
    let execution =
      Option.get (Store.semantic_get store (Scope.direct_operation waiter.operation_id) |> semantic_ok)
    in
    check int "one entry" 1 (List.length execution.receipt_obligations))
;;

let () =
  let pairs =
    List.concat_map
      (fun task ->
         List.map
           (fun event ->
              test_case
                (Wait.task_to_string task ^ ", " ^ Wait.event_to_string event)
                `Quick
                (test_pair task event))
           Wait.all_events)
      Wait.all_tasks
  in
  run
    "keeper_receipt_wait_matrix"
    [ "table", pairs
    ; ( "invariants"
      , [ test_case "one request has one owner" `Quick test_one_request_has_one_owner
        ; test_case
            "a waiting task is not claimed while another runs"
            `Quick
            test_a_waiting_task_is_not_claimed_while_another_runs
        ; test_case
            "a second notice does not pull a running task back"
            `Quick
            test_a_second_notice_does_not_pull_a_running_task_back
        ; test_case
            "a notice for an unowned request changes nothing"
            `Quick
            test_a_notice_for_an_unowned_request_changes_nothing
        ; test_case
            "a source lost notice readies the task like a receipt"
            `Quick
            test_a_source_lost_notice_makes_the_task_ready_like_a_receipt
        ; test_case
            "waiting again on a received request does not wait"
            `Quick
            test_waiting_again_on_a_received_request_does_not_wait
        ] )
    ]
;;
