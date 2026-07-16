open Alcotest
module O = Masc.Keeper_current_operations
module Q = Keeper_event_queue
module S = Keeper_event_queue_state
module A = Masc.Keeper_msg_async
module J = Yojson.Safe.Util

let ok = function Ok value -> value | Error error -> fail error
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

let test_async_terminal_and_unavailable () =
  let entry : A.entry =
    { request_id = "request-1"; keeper_name = "keeper-a"; base_path = "/workspace"
    ; submitted_by = "caller-a"
    ; status = Done { ok = false; body = "failed"; data = Some (`Assoc [ "artifact_ref", `String "artifact-1" ]) }
    ; submitted_at = 5.0; completed_at = Some 6.0 }
  in
  let operation = List.hd (O.project_async_entries [ entry ]) in
  let json = O.to_yojson operation in
  check string "request id" "request-1"
    J.(json |> member "source" |> member "value" |> member "request_id" |> to_string);
  check bool "terminal" true J.(json |> member "source" |> member "value" |> member "status" |> member "terminal" |> to_bool);
  check string "artifact payload" "artifact-1"
    J.(json |> member "source" |> member "value" |> member "status" |> member "data" |> member "artifact_ref" |> to_string);
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
  check bool "async unavailable" false J.(snapshot_json |> member "async_requests" |> member "available" |> to_bool)
;;

let () =
  run "keeper_current_operations"
    [ "projection",
      [ test_case "event queue exact state" `Quick test_event_queue_exact_state
      ; test_case "async terminal and unavailable" `Quick test_async_terminal_and_unavailable
      ] ]
;;
