module P = Keeper_event_queue_persistence
module Q = Keeper_event_queue

type cancellation_outcome =
  | Cancellation_observed
  | Returned
  | Raised of string

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let source_ref () =
  let trace_id =
    match Keeper_id.Trace_id.of_string "exact-lease-guard" with
    | Ok trace_id -> trace_id
    | Error detail -> Alcotest.failf "trace id rejected: %s" detail
  in
  match
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~generation:1
      ~turn_count:1
      ~sha256:(String.make 64 'a')
  with
  | Ok source -> source
  | Error _ -> Alcotest.fail "checkpoint source rejected"
;;

let claim_manual_lease ~base_path ~keeper_name =
  let stimulus : Q.stimulus =
    { post_id = "manual-compaction"
    ; urgency = Q.Immediate
    ; arrived_at = 1.0
    ; payload = Q.Manual_compaction_requested
    }
  in
  (match
     P.update_checked_result
       ~base_path
       ~keeper_name
       (fun pending -> Ok (Q.enqueue pending stimulus))
   with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "manual stimulus persist failed: %s" detail);
  match
    P.claim_when_result
      ~base_path
      ~keeper_name
      ~claimed_at:2.0
      ~ready:(fun _ -> true)
      ()
  with
  | Ok (Some lease) -> lease
  | Ok None -> Alcotest.fail "manual lease was not claimed"
  | Error detail -> Alcotest.failf "manual lease claim failed: %s" detail
;;

let bind_and_quarantine
      ~base_path
      ~keeper_name
      ~cause
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let lease = claim_manual_lease ~base_path ~keeper_name in
  (match
     P.bind_exact_execution_result
       ~base_path
       ~keeper_name
       ~lease
       ~slot_id
       ~call_id
       ~plan_fingerprint
       ~request_body_sha256
       ()
   with
   | Ok P.Durable -> ()
   | Ok (P.Visible_durability_unknown detail) ->
     Alcotest.failf "exact execution bind durability unknown: %s" detail
   | Error detail -> Alcotest.failf "exact execution bind failed: %s" detail);
  let terminal : P.exact_execution_terminal = { cause; slot_id; call_id } in
  (match
     P.quarantine_exact_execution_result
       ~base_path
       ~keeper_name
       ~lease
       ~terminal
       ~plan_fingerprint
       ~request_body_sha256
       ()
   with
   | Ok P.Durable -> ()
   | Ok (P.Visible_durability_unknown detail) ->
     Alcotest.failf "exact execution quarantine durability unknown: %s" detail
   | Error detail -> Alcotest.failf "exact execution quarantine failed: %s" detail);
  lease, terminal
;;

let terminal_settlement source terminal : P.settlement =
  P.No_compaction { source; reason = P.Exact_execution_terminal terminal }
;;

let check_binding ~base_path ~keeper_name ~call_id ~plan_fingerprint =
  match P.exact_execution_binding_result ~base_path ~keeper_name with
  | Ok
      (Some
        { call_id = actual_call_id
        ; plan_fingerprint = actual_plan_fingerprint
        ; status = P.Terminal_quarantined _
        ; _
        }) ->
    Alcotest.(check string) "durable call id" call_id actual_call_id;
    Alcotest.(check string)
      "durable plan fingerprint"
      plan_fingerprint
      actual_plan_fingerprint
  | Ok (Some _) -> Alcotest.fail "binding was not terminally quarantined"
  | Ok None -> Alcotest.fail "durable exact execution binding disappeared"
  | Error detail -> Alcotest.failf "binding load failed: %s" detail
;;

let bind_exact_execution
      ~base_path
      ~keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  match
    P.bind_exact_execution_result
      ~base_path
      ~keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ()
  with
  | Ok P.Durable -> ()
  | Ok (P.Visible_durability_unknown detail) ->
    Alcotest.failf "exact execution bind durability unknown: %s" detail
  | Error detail -> Alcotest.failf "exact execution bind failed: %s" detail
;;

let check_dispatch_uncertain_binding
      ~base_path
      ~keeper_name
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  match P.exact_execution_binding_result ~base_path ~keeper_name with
  | Ok
      (Some
        { slot_id = actual_slot_id
        ; call_id = actual_call_id
        ; plan_fingerprint = actual_plan_fingerprint
        ; request_body_sha256 = actual_request_body_sha256
        ; status = P.Dispatch_uncertain
        ; _
        }) ->
    Alcotest.(check string) "dispatch-uncertain slot" slot_id actual_slot_id;
    Alcotest.(check string) "dispatch-uncertain call" call_id actual_call_id;
    Alcotest.(check string)
      "dispatch-uncertain plan"
      plan_fingerprint
      actual_plan_fingerprint;
    Alcotest.(check string)
      "dispatch-uncertain request"
      request_body_sha256
      actual_request_body_sha256
  | Ok (Some _) -> Alcotest.fail "exact execution binding was not dispatch-uncertain"
  | Ok None -> Alcotest.fail "dispatch-uncertain binding disappeared"
  | Error detail -> Alcotest.failf "dispatch-uncertain binding load failed: %s" detail
;;
