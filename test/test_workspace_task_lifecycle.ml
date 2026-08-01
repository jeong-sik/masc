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

let contains ~needle haystack =
  let nl = String.length needle
  and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.equal (String.sub haystack i nl) needle || go (i + 1)) in
  nl = 0 || go 0
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

(* A verdict is not an agent action. There is no [task_action] constructor for it,
   so the string surface must refuse "approve"/"reject" by naming the authority
   rather than reporting an unknown action — an agent that asks is told why. *)
let test_verdict_is_not_an_agent_action () =
  List.iter
    (fun verb ->
       match D.task_action_of_string verb with
       | Ok _ -> failwith (verb ^ " must not parse as an agent action")
       | Error msg ->
         if not (contains ~needle:"completion authority" msg)
         then failwith (verb ^ " rejection must name the completion authority"))
    [ "approve"; "reject" ]
;;

(* The verdict path is separate from agent actions. The producer boundary owns
   authentication; the leaf still refuses empty provenance so audit identity
   cannot disappear. *)
let test_verdict_requires_authority_and_reason () =
  let operator = D.Human_operator { operator_id = "op-1" } in
  (match
     L.decide_verdict
       ~authority:operator
       ~verdict:D.Verdict_approved
       ~task_id:"task-1"
       ~verification_id:"vrf-1"
       ~task_status:awaiting
       ~now
       ~notes:"evidence at /tmp/proof"
   with
   | Ok
       { decision = { new_status = D.Done { assignee; _ }; _ }
       ; authority = D.Human_operator { operator_id }
       ; producer
       ; verification_id
       }
     when String.equal assignee owner
          && String.equal operator_id "op-1"
          && String.equal producer owner
          && String.equal verification_id "vrf-1" -> ()
   | Ok _ | Error _ -> failwith "operator approval must complete the task");
  (match
     L.decide_verdict
       ~authority:operator
       ~verdict:(D.Verdict_rejected { reason = " " })
       ~task_id:"task-1"
       ~verification_id:"vrf-1"
       ~task_status:awaiting
       ~now
       ~notes:""
   with
   | Error L.Verdict_rejection_reason_required -> ()
   | Ok _ | Error _ -> failwith "a blank rejection reason must be refused");
  (match
     L.decide_verdict
       ~authority:(D.Human_operator { operator_id = " " })
       ~verdict:D.Verdict_approved
       ~task_id:"task-1"
       ~verification_id:"vrf-1"
       ~task_status:awaiting
       ~now
       ~notes:""
   with
   | Error L.Verdict_authority_identity_required -> ()
   | Ok _ | Error _ -> failwith "a blank authority identity must be refused");
  match
    L.decide_verdict
      ~authority:(D.System_llm_agent { agent_run_id = "fusion-run-9" })
      ~verdict:(D.Verdict_rejected { reason = "missing test evidence" })
      ~task_id:"task-1"
      ~verification_id:"vrf-1"
      ~task_status:awaiting
      ~now
      ~notes:""
  with
  | Ok
      { decision = { new_status = D.InProgress { assignee; _ }; _ }
      ; authority = D.System_llm_agent { agent_run_id }
      ; producer
      ; verification_id
      }
    when String.equal assignee owner
         && String.equal agent_run_id "fusion-run-9"
         && String.equal producer owner
         && String.equal verification_id "vrf-1" -> ()
  | Ok _ | Error _ -> failwith "judge rejection must return the task to its producer"
;;

let test_verdict_rejects_stale_verification_id () =
  match
    L.decide_verdict
      ~authority:(D.System_llm_agent { agent_run_id = "judge-run-1" })
      ~verdict:D.Verdict_approved
      ~task_id:"task-1"
      ~verification_id:"vrf-stale"
      ~task_status:awaiting
      ~now
      ~notes:""
  with
  | Error (L.Verification_id_mismatch { expected; actual })
    when String.equal expected "vrf-stale" && String.equal actual "vrf-1" -> ()
  | Ok _ | Error _ -> failwith "a stale verification verdict must be refused"
;;

(* Claiming an obligation used to bind the claimant as its verifier, so whichever
   keeper won the race held approval authority. Nobody claims it now. *)
let test_claim_on_awaiting_is_refused () =
  decide ~same_agent:false ~task_status:awaiting ~action:D.Claim ()
  |> expect_error L.Verification_pending_verdict
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

(* Inverts the removed authority-by-claim behaviour. Previously the producer was
   refused and any peer that claimed became the verifier; now no actor at all can
   claim an obligation that is awaiting a verdict. *)
let test_awaiting_is_claimable_by_nobody () =
  let task = task_with_status awaiting in
  List.iter
    (fun actor ->
       match L.resolve_claim ~same_actor:(String.equal actor) ~agent_name:actor ~now task with
       | L.Held_pending_verdict { verification_id }
         when String.equal verification_id "vrf-1" -> ()
       | _ ->
         failwith (actor ^ " must not claim an obligation awaiting a completion verdict"))
    [ owner; "verifier"; "other" ]
;;

let () =
  test_done_requires_verification_submission ();
  test_claimed_done_requires_verification_submission ();
  test_default_done_is_terminal ();
  test_verdict_is_not_an_agent_action ();
  test_verdict_requires_authority_and_reason ();
  test_verdict_rejects_stale_verification_id ();
  test_claim_on_awaiting_is_refused ();
  test_awaiting_is_claimable_by_nobody ();
  Printf.printf "workspace_task_lifecycle: all tests passed\n%!"
