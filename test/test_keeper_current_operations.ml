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

(* [test_event_queue_exact_state] drove S.claim_when -> project -> S.settle and
   asserted the Event_queue_lease projection and the resulting outbox receipt.
   #25969 moved production to peek/ack; claim_when, settle and the
   Event_queue_lease source are gone, so the case has no subject. *)

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

let test_pending_operations_expose_source_incarnations () =
  let first = stimulus "source-a" 1.0 in
  let second = stimulus "source-b" 2.0 in
  let first_state =
    S.empty
    |> S.with_pending (queue [ first ])
    |> S.with_revision 1L
  in
  let state =
    first_state
    |> S.with_pending (queue [ first; second ])
    |> S.with_revision 2L
  in
  let operations = O.project_event_queue_state ~keeper_name:"keeper-a" state in
  let incarnations =
    operations
    |> List.map (fun operation ->
      O.to_yojson operation
      |> J.member "source"
      |> J.member "source_incarnation"
      |> J.to_string)
  in
  check (list string)
    "pending operations retain each source incarnation"
    [ "0"; "1" ]
    incarnations;
  let snapshot =
    O.project_snapshot
      ~keeper_name:"keeper-a"
      ~event_queue:(Ok state)
      ~async_requests:(Ok [])
    |> O.snapshot_to_yojson
  in
  check string
    "source-incarnation wire has a new schema"
    "keeper.current_operations.v2"
    J.(snapshot |> member "schema" |> to_string)
;;

let () =
  run "keeper_current_operations"
    [ "projection",
      [ test_case "async active and unavailable" `Quick test_async_active_and_unavailable
      ; test_case "terminal async is not current" `Quick
          test_terminal_async_entry_is_not_current
      ; test_case "pending source incarnations" `Quick
          test_pending_operations_expose_source_incarnations
      ] ]
;;
