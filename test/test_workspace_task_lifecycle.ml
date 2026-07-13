module L = Workspace_task_lifecycle
module D = Masc_domain

let owner = "alice"
let now = "2026-07-13T00:00:00Z"

let pass =
  { D.decision = D.Completion_pass
  ; runtime_id = "task-reviewer"
  ; rationale = None
  ; evaluated_at = now
  }
;;

let reject reason =
  { D.decision = D.Completion_reject reason
  ; runtime_id = "task-reviewer"
  ; rationale = Some reason
  ; evaluated_at = now
  }
;;

let unavailable reason =
  { D.decision = D.Completion_verdict_unavailable reason
  ; runtime_id = "task-reviewer"
  ; rationale = Some reason
  ; evaluated_at = now
  }
;;

let decide ?configured_llm_verdict ~same_agent ~task_status ~action () =
  L.decide
    ~new_verification_id:(fun () -> "vrf-1")
    ~same_agent:(fun _ -> same_agent)
    ~agent_name:owner
    ~task_id:"task-1"
    ~task_status
    ~action
    ~now
    ~configured_llm_verdict
    ~notes:"evidence at /tmp/proof"
    ~reason:""
;;

let in_progress = D.InProgress { assignee = owner; started_at = now }

let awaiting =
  D.AwaitingVerification
    { assignee = owner
    ; submitted_at = now
    ; verification_id = "vrf-1"
    ; phase = D.Awaiting_verifier
    }
;;

let expect_error expected = function
  | Error actual when actual = expected -> ()
  | Error _ -> failwith "unexpected lifecycle error"
  | Ok _ -> failwith "expected lifecycle error"
;;

let test_done_requires_configured_llm_pass () =
  decide ~same_agent:true ~task_status:in_progress ~action:D.Done_action ()
  |> expect_error L.Completion_verdict_required;
  decide
    ~configured_llm_verdict:(reject "tests missing")
    ~same_agent:true
    ~task_status:in_progress
    ~action:D.Done_action
    ()
  |> expect_error (L.Completion_rejected "tests missing");
  decide
    ~configured_llm_verdict:(unavailable "runtime unavailable")
    ~same_agent:true
    ~task_status:in_progress
    ~action:D.Done_action
    ()
  |> expect_error (L.Completion_verdict_unavailable "runtime unavailable");
  match
    decide
      ~configured_llm_verdict:pass
      ~same_agent:true
      ~task_status:in_progress
      ~action:D.Done_action
      ()
  with
  | Ok { new_status = D.Done _; _ } -> ()
  | Ok _ | Error _ -> failwith "configured LLM pass must complete owned in-progress task"
;;

let test_claimed_can_complete_after_configured_llm_pass () =
  let claimed = D.Claimed { assignee = owner; claimed_at = now } in
  match
    decide
      ~configured_llm_verdict:pass
      ~same_agent:true
      ~task_status:claimed
      ~action:D.Done_action
      ()
  with
  | Ok { new_status = D.Done _; _ } -> ()
  | Ok _ | Error _ -> failwith "configured LLM pass must complete an owned claimed task"
;;

let test_actor_relationship_does_not_authorize_verdict () =
  (match
     decide
       ~configured_llm_verdict:pass
       ~same_agent:true
       ~task_status:awaiting
       ~action:D.Approve_verification
       ()
   with
   | Ok { new_status = D.Done _; _ } -> ()
   | Ok _ | Error _ -> failwith "submitter may deliver a configured LLM pass");
  (match
     decide
       ~configured_llm_verdict:(reject "fix failing test")
       ~same_agent:false
       ~task_status:awaiting
       ~action:D.Reject_verification
       ()
   with
   | Ok { new_status = D.InProgress { assignee; _ }; _ }
     when String.equal assignee owner -> ()
   | Ok _ | Error _ -> failwith "configured LLM reject must return task to owner")
;;

let test_awaiting_claim_is_only_scheduling_binding () =
  let task : D.task =
    { id = "task-1"
    ; title = "review"
    ; description = ""
    ; task_status = awaiting
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
  in
  match L.resolve_claim ~same_actor:(fun _ -> true) ~agent_name:owner ~now task with
  | L.Verifier_claim (D.AwaitingVerification { phase = D.Verifier_assigned _; _ }) -> ()
  | _ -> failwith "same actor may bind awaiting verification for scheduling"
;;

let () =
  test_done_requires_configured_llm_pass ();
  test_claimed_can_complete_after_configured_llm_pass ();
  test_actor_relationship_does_not_authorize_verdict ();
  test_awaiting_claim_is_only_scheduling_binding ();
  Printf.printf "workspace_task_lifecycle: all tests passed\n%!"
