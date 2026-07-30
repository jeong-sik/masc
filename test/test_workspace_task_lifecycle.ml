module L = Workspace_task_lifecycle
module D = Masc_domain

let owner = "alice"
let now = "2026-07-13T00:00:00Z"

let decide
      ?(requires_verification = true)
      ?(notes = "evidence at /tmp/proof")
      ?(reason = "")
      ~same_agent
      ~task_status
      ~action
      ()
  =
  L.decide
    ~new_verification_id:(fun () -> "vrf-1")
    ~same_agent:(fun _ -> same_agent)
    ~agent_name:owner
    ~task_id:"task-1"
    ~task_status
    ~requires_verification
    ~action
    ~now
    ~notes
    ~reason
;;

let in_progress = D.InProgress { assignee = owner; started_at = now }

let awaiting =
  D.AwaitingVerification
    { assignee = owner
    ; submitted_at = now
    ; verification_id = "vrf-1"
    }
;;

let assigned verifier =
  D.AwaitingVerification
    { assignee = owner
    ; submitted_at = now
    ; verification_id = "vrf-1"
    ; phase = D.Verifier_assigned { verifier }
    }
;;

let expect_error expected = function
  | Error actual when actual = expected -> ()
  | Error _ -> failwith "unexpected lifecycle error"
  | Ok _ -> failwith "expected lifecycle error"
;;

let test_done_requires_verification_submission () =
  decide ~same_agent:true ~task_status:in_progress ~action:D.Done_action ()
  |> expect_error L.Verification_submission_required
;;

let test_claimed_done_requires_verification_submission () =
  let claimed = D.Claimed { assignee = owner; claimed_at = now } in
  decide ~same_agent:true ~task_status:claimed ~action:D.Done_action ()
  |> expect_error L.Verification_submission_required
;;

let test_default_done_is_terminal () =
  match
    decide
      ~requires_verification:false
      ~same_agent:true
      ~task_status:in_progress
      ~action:D.Done_action
      ()
  with
  | Ok { new_status = D.Done { assignee; _ }; _ }
    when String.equal assignee owner -> ()
  | Ok _ | Error _ -> failwith "advisory/default owner completion must be terminal"
;;

let test_verdict_requires_assigned_winner () =
  decide
    ~same_agent:false
    ~task_status:awaiting
    ~action:D.Approve_verification
    ()
  |> expect_error L.Verification_claim_required;
  decide
    ~same_agent:false
    ~task_status:(assigned "verifier")
    ~action:D.Approve_verification
    ()
  |> expect_error (L.Verification_assigned_to "verifier");
  (match
     decide ~same_agent:true
       ~task_status:(assigned "verifier") ~action:D.Approve_verification ()
   with
   | Ok { new_status = D.Done _; _ } -> ()
   | Ok _ | Error _ -> failwith "assigned winner must be able to approve");
  match
    decide ~same_agent:true
      ~task_status:(assigned "verifier") ~action:D.Reject_verification ()
  with
  | Ok { new_status = D.InProgress { assignee; _ }; _ }
    when String.equal assignee owner -> ()
  | Ok _ | Error _ -> failwith "assigned winner reject must return task to producer"
;;

let test_verdict_requires_justification_before_commit () =
  decide
    ~notes:"  "
    ~same_agent:true
    ~task_status:(assigned "verifier")
    ~action:D.Approve_verification
    ()
  |> expect_error L.Verification_approval_notes_required;
  decide
    ~notes:""
    ~reason:" "
    ~same_agent:true
    ~task_status:(assigned "verifier")
    ~action:D.Reject_verification
    ()
  |> expect_error L.Verification_rejection_reason_required;
  match
    decide
      ~notes:""
      ~reason:"missing test evidence"
      ~same_agent:true
      ~task_status:(assigned "verifier")
      ~action:D.Reject_verification
      ()
  with
  | Ok { new_status = D.InProgress _; _ } -> ()
  | Ok _ | Error _ -> failwith "non-empty rejection reason must be accepted"
;;

let task_with_status task_status : D.task =
  { id = "task-1"
  ; title = "review"
  ; description = ""
  ; task_status
  ; priority = 1
  ; files = []
  ; created_at = now
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }
;;

let test_awaiting_claim_has_one_non_producer_winner () =
  let task : D.task =
    task_with_status awaiting
  in
  (match L.resolve_claim ~same_actor:(String.equal owner) ~agent_name:owner ~now task with
   | L.Self_verification -> ()
   | _ -> failwith "producer must not claim its own verification");
  let won =
    match L.resolve_claim ~same_actor:(String.equal "verifier") ~agent_name:"verifier" ~now task with
    | L.Verifier_claim
        (D.AwaitingVerification
          ({ phase = D.Verifier_assigned { verifier = "verifier" }; _ } as status)) ->
      D.AwaitingVerification status
    | _ -> failwith "peer verifier must claim the awaiting obligation"
  in
  (match
     L.resolve_claim ~same_actor:(String.equal "verifier") ~agent_name:"verifier" ~now
       (task_with_status won)
   with
   | L.Self_owned -> ()
   | _ -> failwith "winner must retain its assignment");
  match
    L.resolve_claim ~same_actor:(String.equal "other") ~agent_name:"other" ~now
      (task_with_status won)
  with
  | L.Held_by_other "verifier" -> ()
  | _ -> failwith "another verifier must not steal the assignment"
;;

let () =
  test_done_requires_verification_submission ();
  test_claimed_done_requires_verification_submission ();
  test_default_done_is_terminal ();
  test_verdict_requires_assigned_winner ();
  test_verdict_requires_justification_before_commit ();
  test_awaiting_claim_has_one_non_producer_winner ();
  Printf.printf "workspace_task_lifecycle: all tests passed\n%!"
