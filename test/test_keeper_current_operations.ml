open Alcotest
module O = Masc.Keeper_current_operations
module Q = Keeper_event_queue
module S = Keeper_event_queue_state
module A = Masc.Keeper_msg_async
module J = Yojson.Safe.Util

let ok = function Ok value -> value | Error error -> fail error
let ok_projection = function Ok value -> value | Error _ -> fail "projection failed"
let stimulus id at = { Q.post_id = id; urgency = Normal; arrived_at = at; payload = Bootstrap }
let queue xs = List.fold_left Q.enqueue Q.empty xs

let test_event_queue_exact_state () =
  let first = stimulus "wake-1" 1.0 and second = stimulus "wake-2" 2.0 in
  let state = S.empty |> S.with_pending (queue [ first; second ]) |> S.with_revision 17L in
  let state, lease = S.claim_when ~claimed_at:3.0 ~ready:(fun _ -> true) state |> ok in
  let lease = Option.get lease in
  (match O.project_event_queue_state ~keeper_name:"keeper-a" state with
   | [ { source = Event_queue_lease { revision; lease = projected }; _ }
     ; { source = Event_queue_pending { stimulus = pending; _ }; _ } ] ->
     check string "lease id" lease.lease_id projected.lease_id;
     check int64 "revision" 17L revision;
     check string "pending identity" second.post_id pending.post_id
   | operations -> failf "unexpected operation count=%d" (List.length operations));
  let state, _ = S.settle ~settled_at:4.0 ~lease ~settlement:S.Ack state |> ok in
  match O.project_event_queue_state ~keeper_name:"keeper-a" state with
  | [ { source = Event_queue_pending _; _ }
    ; ({ source = Event_queue_outbox { entry; _ }; _ } as operation) ] ->
    check string "transition" "lease:1:ack" entry.receipt.transition_id;
    check string "render is exact JSON"
      (O.to_yojson operation |> Yojson.Safe.to_string) (O.render operation)
  | operations -> failf "unexpected outbox operation count=%d" (List.length operations)
;;

let test_event_queue_parked_is_exact_and_nonterminal_only () =
  let source = stimulus "overflow-source" 1.0 in
  let state = S.empty |> S.with_pending (queue [ source ]) |> S.with_revision 23L in
  let state, lease = S.claim_when ~claimed_at:2.0 ~ready:(fun _ -> true) state |> ok in
  let lease = Option.get lease in
  let operation_id = Keeper_compaction_operation_identity.Operation_id.generate () in
  let state, settlement =
    S.park_for_compaction ~settled_at:3.0 ~lease ~operation_id state
    |> Result.map_error S.parking_error_to_string
    |> ok
  in
  let receipt =
    match settlement with
    | S.Settled receipt -> receipt
    | S.Already_settled _ -> fail "first park was already settled"
  in
  let state =
    S.mark_transition_projected ~transition_id:receipt.transition_id state |> ok
  in
  (match O.project_event_queue_state ~keeper_name:"keeper-a" state with
   | [ ({ source = Event_queue_parked { revision; entry }; _ } as operation) ] ->
     check int64 "revision" 23L revision;
     check bool "operation id" true
       (Keeper_compaction_operation_identity.Operation_id.equal
          operation_id
          entry.operation_id);
     check string "source lease" lease.lease_id entry.source_lease.lease_id;
     check string "projection kind" "event_queue_parked"
       J.(O.to_yojson operation |> member "source" |> member "kind" |> to_string)
   | operations -> failf "unexpected parked operation count=%d" (List.length operations));
  let resumed, _ =
    S.resume_parked ~operation_id state
    |> Result.map_error S.parking_error_to_string
    |> ok
  in
  match O.project_event_queue_state ~keeper_name:"keeper-a" resumed with
  | [ { source = Event_queue_pending _; _ } ] -> ()
  | operations ->
    failf "resumed audit row remained current count=%d" (List.length operations)
;;

let test_async_active_and_unavailable () =
  let entry : A.entry =
    { request_id = "request-1"; keeper_name = "keeper-a"; base_path = "/workspace"
    ; submitted_by = "caller-a"
    ; status = Running
    ; submitted_at = 5.0; completed_at = None }
  in
  let operation =
    O.project_async_entries ~keeper_name:"keeper-a" [ entry ]
    |> ok_projection
    |> List.hd
  in
  let json = O.to_yojson operation in
  check string "request id" "request-1"
    J.(json |> member "source" |> member "value" |> member "request_id" |> to_string);
  check bool "terminal" false
    J.(json |> member "source" |> member "value" |> member "status"
       |> member "terminal" |> to_bool);
  let snapshot =
    O.project_snapshot ~keeper_name:"keeper-a"
      ~event_queue:(Error (O.Durable_read_failed "corrupt state"))
      ~async_requests:(Error (O.Access_rejected A.Caller_mismatch))
  in
  (match snapshot.event_queue, snapshot.async_requests with
   | Unavailable { error = Durable_read_failed _; _ },
     Unavailable { error = Access_rejected Caller_mismatch; _ } -> ()
   | _ -> fail "source failures were not preserved as typed Unavailable");
  let snapshot_json = O.snapshot_to_yojson snapshot in
  check bool "event unavailable" false J.(snapshot_json |> member "event_queue" |> member "available" |> to_bool);
  check bool "async unavailable" false J.(snapshot_json |> member "async_requests" |> member "available" |> to_bool);
  let wrong_keeper = { entry with keeper_name = "keeper-b" } in
  let mixed_snapshot =
    O.project_snapshot ~keeper_name:"keeper-a"
      ~event_queue:(Ok S.empty)
      ~async_requests:(Ok [ wrong_keeper ])
  in
  match mixed_snapshot.async_requests with
  | Unavailable
      { error =
          Async_keeper_mismatch
            { request_id = "request-1"
            ; expected_keeper = "keeper-a"
            ; actual_keeper = "keeper-b"
            }
      ; _
      } ->
    ()
  | _ -> fail "cross-keeper async entry was not rejected"
;;

let test_terminal_async_entry_is_not_current () =
  let terminal : A.entry =
    { request_id = "request-terminal"
    ; keeper_name = "keeper-a"
    ; base_path = "/workspace"
    ; submitted_by = "caller-a"
    ; status = Done { ok = true; body = "done"; data = None }
    ; submitted_at = 5.0
    ; completed_at = Some 6.0
    }
  in
  match O.project_async_entries ~keeper_name:"keeper-a" [ terminal ] with
  | Error (O.Async_terminal_entry { request_id = "request-terminal"; _ }) -> ()
  | _ -> fail "terminal async entry was projected as a current operation"
;;

let () =
  run "keeper_current_operations"
    [ "projection",
      [ test_case "event queue exact state" `Quick test_event_queue_exact_state
      ; test_case
          "event queue parked exact state"
          `Quick
          test_event_queue_parked_is_exact_and_nonterminal_only
      ; test_case "async active and unavailable" `Quick test_async_active_and_unavailable
      ; test_case "terminal async is not current" `Quick
          test_terminal_async_entry_is_not_current
      ] ]
;;
