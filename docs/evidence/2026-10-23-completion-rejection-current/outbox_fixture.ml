open Alcotest
module D = Masc_domain
module O = Workspace_task_rejection_outbox
module C = Workspace_utils_backend_setup
let at = "2026-10-23T00:00:00Z"
let authority = D.Human_operator {operator_id="operator-a"}
let receipt ?(verification_id="verification-a") () : D.pending_completion_rejection =
  {task_id="task-a";verification_id;producer="keeper-a";reason="Repair evidence";
   authority;committed_at=at}
let task () =
  D.task_of_yojson (`Assoc ["id",`String "task-a";"title",`String "Repair task";
    "description",`String "Actual task codec";"status",`String "in_progress";
    "assignee",`String "keeper-a";"started_at",`String at;
    "created_at",`String at;"priority",`Int 1;"files",`List []]) |> Result.get_ok
let backlog () : D.backlog =
  {tasks=[task ()];pending_completion_rejections=[receipt ()];
   delivered_completion_rejections=[];pending_completion_approvals=[];
   task_creation_receipts=[];task_deletion_receipts=[];last_updated=at;version=1}
let current ?(verification_id="verification-a") ?(producer="keeper-a")
    ?(reason="Repair evidence") ?(authority=authority) config =
  O.standing config ~task_id:"task-a" ~verification_id ~producer ~reason ~authority
let publish ?(verification_id="verification-a") ?(producer="keeper-a")
    ?(reason="Repair evidence") ?(authority=authority) config deliver =
  O.deliver_if_pending config ~task_id:"task-a" ~verification_id ~producer ~reason
    ~authority ~deliver
let ack config verification_id = O.acknowledge config ~task_id:"task-a" ~verification_id
let ok = function Ok value -> value | Error detail -> fail detail
let error = function Error _ -> () | Ok _ -> fail "uncertain or conflicting input was accepted"
let assert_current config = match ok (current config) with
  | O.Current -> () | O.Obsolete -> fail "current relation was lost"
let assert_released config =
  check bool "backlog lock released" false config.C.lock_held;
  check bool "lease fence released" false config.C.fence_held
let encoded config = D.backlog_to_yojson config.C.snapshot |> Yojson.Safe.to_string
let queue config calls result () =
  check bool "actual Outbox calls queue under backlog lock" true config.C.lock_held;
  check bool "actual Outbox calls queue under current lease fence" true config.C.fence_held;
  incr calls;result
let forbid calls () = incr calls;fail "a stale or unavailable relation published to the queue"

let test_normal_publication_ack_and_duplicate_ack () =
  let fields = match D.backlog_to_yojson (backlog ()) with
    | `Assoc fields -> fields | _ -> fail "backlog encoder must produce an object" in
  let snapshot = D.backlog_of_yojson
    (`Assoc (List.remove_assoc "delivered_completion_rejections" fields)) |> ok in
  let config=C.make snapshot in let calls=ref 0 in
  assert_current config;
  check int "pending delivery observed" 1 (List.length (ok (O.pending config)));
  (match ok (publish config (queue config calls (Ok "queue-receipt"))) with
   | O.Published value -> check string "the actual callback receipt returns" "queue-receipt" value
   | O.Superseded -> fail "current pending work was suppressed");
  check int "one queue publication" 1 !calls;
  check int "queue publication alone does not ACK" 1
    (List.length config.snapshot.pending_completion_rejections);
  check int "no premature delivered claim" 0
    (List.length config.snapshot.delivered_completion_rejections);
  ok (ack config "verification-a");
  check bool "same complete relation moves to delivered" true
    (config.snapshot.pending_completion_rejections=[]
      && config.snapshot.delivered_completion_rejections=[receipt ()]);
  check int "exact ACK commits once" 1 config.committed_writes;
  assert_current config;
  let before=encoded config in ok (ack config "verification-a");
  check string "duplicate ACK leaves bytes stable" before (encoded config);
  check int "duplicate ACK does not rewrite" 1 config.committed_writes;
  (match ok (publish config (forbid calls)) with
   | O.Superseded -> () | O.Published _ -> fail "delivered relation republished");
  check int "no delivery after ACK" 1 !calls;
  assert_released config

let test_replacement_before_lock_and_old_ack () =
  List.iter (fun rejected_b ->
    let config=C.make (backlog ()) in let calls=ref 0 in
    ignore (ok (O.pending config));
    config.before_lock <- Some (fun () ->
      let tasks=if rejected_b then config.snapshot.tasks else
        List.map (fun (task:D.task) -> {task with task_status=D.AwaitingVerification
          {assignee="keeper-a";started_at=at;submitted_at=at;verification_id="verification-b"}})
          config.snapshot.tasks in
      config.snapshot <- {config.snapshot with tasks;
        pending_completion_rejections=(if rejected_b then [receipt ~verification_id:"verification-b" ()] else []);
        delivered_completion_rejections=[]});
    (match ok (publish config (forbid calls)) with
     | O.Superseded -> () | O.Published _ -> fail "old snapshot authorized publication");
    check bool "authority reread only inside fence" true
      (List.hd config.read_scopes=(true,true));
    let before=encoded config in ok (ack config "verification-a");
    check string "old ACK preserves replacement Task/relation" before (encoded config);
    check int "stale ACK writes nothing" 0 config.committed_writes;
    check int "old A never queued after B replaced it" 0 !calls;
    assert_released config) [false;true]

let test_exact_payload_and_owner_conflicts () =
  let altered_authority = D.System_llm_agent {agent_run_id="run-other"} in
  let variants=[(fun c -> publish ~producer:"other-keeper" c);
    (fun c -> publish ~reason:"different reason" c);
    (fun c -> publish ~authority:altered_authority c)] in
  List.iter (fun invoke ->
    let config=C.make (backlog ()) in let calls=ref 0 in let before=encoded config in
    error (invoke config (forbid calls));
    check int "payload conflict never queues" 0 !calls;
    check string "payload conflict preserves storage" before (encoded config);
    assert_released config) variants;
  List.iter (fun task_status ->
    let config=C.make (backlog ()) in let calls=ref 0 in
    config.snapshot <- {config.snapshot with tasks=List.map (fun (t:D.task) ->
      {t with task_status}) config.snapshot.tasks};
    error (current config);error (publish config (forbid calls));
    check int "inconsistent Task never queues" 0 !calls;assert_released config)
    [D.InProgress {assignee="different-owner";started_at=at};D.Todo];
  let config=C.make (backlog ()) in let calls=ref 0 in
  config.snapshot <- {config.snapshot with delivered_completion_rejections=[receipt ()]};
  error (current config);error (publish config (forbid calls));
  check int "duplicate current relation never queues" 0 !calls

let test_unread_and_lock_failure_preserve_source () =
  List.iter (fun lock_failure ->
    let config=C.make (backlog ()) in let calls=ref 0 in let before=encoded config in
    if lock_failure then config.lock_failure <- Some (D.Lock_unavailable "injected lock unavailable")
    else config.read_failure <- Some "injected unreadable authoritative primary";
    error (publish config (forbid calls));error (ack config "verification-a");
    check int "unavailable authority never queues" 0 !calls;
    check int "unavailable authority never writes" 0 config.write_attempts;
    check string "unavailable authority preserves source" before (encoded config);
    if lock_failure then check int "failed lock reads nothing" 0 config.read_attempts
    else (error (O.pending config);error (current config));
    assert_released config) [false;true]

let test_lease_takeover_never_enters_callback () =
  let config=C.make (backlog ()) in let calls=ref 0 in let before=encoded config in
  config.before_fence <- Some (fun () -> config.lease_lost <- true);
  error (publish config (forbid calls));
  check int "lost lease rejects before authority reread" 0 config.read_attempts;
  check int "lost lease never calls queue" 0 !calls;
  check string "lost lease preserves pending source" before (encoded config);
  assert_released config

let test_queue_and_ack_write_failure_keep_pending () =
  let config=C.make (backlog ()) in let calls=ref 0 in let before=encoded config in
  error (publish config (queue config calls (Error "injected queue publication failure")));
  check int "queue port was reached exactly once" 1 !calls;
  check string "queue failure preserves complete pending source" before (encoded config);
  check int "queue failure never marks delivered" 0 config.committed_writes;
  (match ok (publish config (queue config calls (Ok ()))) with
   | O.Published () -> () | O.Superseded -> fail "same pending identity could not replay");
  config.write_failure <- Some "injected backlog commit failure";
  error (ack config "verification-a");
  check string "ACK write failure leaves the crash-gap pending relation" before (encoded config);
  assert_current config;
  check int "failed commit marks no delivered receipt" 0 config.committed_writes;
  config.write_failure <- None;ok (ack config "verification-a");
  check bool "retry moves the original full record" true
    (config.snapshot.delivered_completion_rejections=[receipt ()]);
  assert_released config

let test_known_absence_is_obsolete () =
  let config=C.make { (backlog ()) with tasks=[];pending_completion_rejections=[] } in
  let calls=ref 0 in
  (match ok (current config) with O.Obsolete -> () | O.Current -> fail "deleted Task granted authority");
  (match ok (publish config (forbid calls)) with O.Superseded -> () | O.Published _ -> fail "missing relation published");
  check int "known absence never publishes" 0 !calls;assert_released config

let without_relation_wire tasks =
  let snapshot = {(backlog ()) with tasks;pending_completion_rejections=[];
    delivered_completion_rejections=[]} in
  let fields = match D.backlog_to_yojson snapshot with
    | `Assoc fields -> fields
    | _ -> fail "backlog encoder must produce an object" in
  D.backlog_of_yojson (`Assoc (List.remove_assoc "delivered_completion_rejections" fields)) |> ok

let test_absent_relation_preserves_possible_old_source () =
  let config=C.make (without_relation_wire [task ()]) in
  check int "main-format Task remains readable" 1 (List.length config.snapshot.tasks);
  check int "absent field supplies no delivered fact" 0
    (List.length config.snapshot.delivered_completion_rejections);
  let before=encoded config and calls=ref 0 in
  error (current config);
  (match ok (publish config (forbid calls)) with
   | O.Superseded -> () | O.Published _ -> fail "absent pending identity granted new publication");
  check int "uncertain existing source is never requeued" 0 !calls;
  ok (ack config "verification-a");
  check string "old ACK cannot manufacture delivered authority" before (encoded config);
  check int "old ACK commits nothing" 0 config.committed_writes;
  assert_released config

let test_positive_task_state_retires_unobserved_source () =
  let states = [Some D.Todo;
    Some (D.Claimed {assignee="keeper-a";claimed_at=at});
    Some (D.InProgress {assignee="new-owner";started_at=at});
    Some (D.AwaitingVerification {assignee="keeper-a";started_at=at;submitted_at=at;
      verification_id="verification-b"});
    Some (D.Done {assignee="keeper-a";completed_at=at;notes=None});
    Some (D.Cancelled {cancelled_by="keeper-a";cancelled_at=at;reason=None});None] in
  List.iter (fun status ->
    let tasks = match status with None -> [] | Some task_status -> [{(task ()) with task_status}] in
    let config=C.make (without_relation_wire tasks) and calls=ref 0 in
    let before=encoded config in
    (match ok (current config) with O.Obsolete -> () | O.Current -> fail "retired producer granted intake");
    (match ok (publish config (forbid calls)) with
     | O.Superseded -> () | O.Published _ -> fail "retired producer granted new queue publication");
    ok (ack config "verification-a");
    check int "positive retirement never publishes" 0 !calls;
    check string "source ACK cannot alter current Task" before (encoded config);
    assert_released config) states

let () = run "actual rejection outbox with explicit storage and lease ports"
  ["current authority",[
    test_case "publication then exact and duplicate ACK" `Quick test_normal_publication_ack_and_duplicate_ack;
    test_case "replacement before lock preserves B against old enqueue and ACK" `Quick test_replacement_before_lock_and_old_ack;
    test_case "payload owner and duplicate relation conflict" `Quick test_exact_payload_and_owner_conflicts;
    test_case "unread primary and lock failure keep source" `Quick test_unread_and_lock_failure_preserve_source;
    test_case "lease takeover never enters publication" `Quick test_lease_takeover_never_enters_callback;
    test_case "queue and ACK failure preserve crash-gap authority" `Quick test_queue_and_ack_write_failure_keep_pending;
    test_case "known deleted Task makes missing relation obsolete" `Quick test_known_absence_is_obsolete;
    test_case "absent relation preserves possible old source without publication grant" `Quick test_absent_relation_preserves_possible_old_source;
    test_case "positive Task state retires unobserved old source" `Quick test_positive_task_state_retires_unobserved_source;
  ]]
