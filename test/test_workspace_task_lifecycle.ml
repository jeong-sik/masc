module L = Workspace_task_lifecycle
module D = Masc_domain

let owner = "alice"
let now = "2026-07-13T00:00:00Z"
let producer_reason = "the premise no longer holds"

let producer_stated ~verification_id:_ =
  Workspace_verification_store.Cancellation_reason_stated producer_reason
;;

let decide
      ?(notes = "evidence at /tmp/proof")
      ?reason
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
    ~action
    ~now
    ~notes
    ~reason
;;

let in_progress = D.InProgress { assignee = owner; started_at = now }

let awaiting =
  D.AwaitingVerification
    { assignee = owner
    ; started_at = now
    ; submitted_at = now
    ; intent = Complete_task
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

let test_done_has_no_non_verification_lane () =
  decide ~same_agent:true ~task_status:in_progress ~action:D.Done_action ()
  |> expect_error L.Verification_submission_required
;;

(* The holder ends its own Task at once, with the reason on the record. *)
let cancelled_with_reason ~what = function
  | Ok { L.new_status = D.Cancelled { cancelled_by; reason; _ }; _ } ->
    if not (String.equal cancelled_by owner)
    then failwith (what ^ ": the canceller must be recorded");
    if reason <> Some producer_reason
    then failwith (what ^ ": the stated reason must be recorded")
  | Ok { L.new_status = D.AwaitingVerification _; _ } ->
    failwith (what ^ ": a holder's cancel must not wait for anyone")
  | Ok _ -> failwith (what ^ ": cancel did not end the task")
  | Error _ -> failwith (what ^ ": cancel was refused")
;;

let test_holder_cancel_ends_the_task_at_once () =
  let claimed = D.Claimed { assignee = owner; claimed_at = now } in
  decide ~reason:producer_reason ~same_agent:true ~task_status:claimed ~action:D.Cancel ()
  |> cancelled_with_reason ~what:"claimed";
  decide ~reason:producer_reason ~same_agent:true ~task_status:in_progress ~action:D.Cancel ()
  |> cancelled_with_reason ~what:"in progress"
;;

(* A pending submission is the producer's own, so withdrawing it ends the Task
   the same way. *)
let test_cancel_of_a_pending_submission_ends_the_task () =
  decide ~reason:producer_reason ~same_agent:true ~task_status:awaiting ~action:D.Cancel ()
  |> cancelled_with_reason ~what:"pending submission"
;;

let test_holder_cancel_requires_a_reason () =
  decide ~same_agent:true ~task_status:in_progress ~action:D.Cancel ()
  |> expect_error L.Cancel_reason_required;
  decide ~same_agent:true ~task_status:awaiting ~action:D.Cancel ()
  |> expect_error L.Cancel_reason_required
;;

let test_cancel_of_someone_elses_task_is_refused () =
  decide ~reason:producer_reason ~same_agent:false ~task_status:in_progress ~action:D.Cancel ()
  |> expect_error L.Invalid_transition;
  decide ~reason:producer_reason ~same_agent:false ~task_status:awaiting ~action:D.Cancel ()
  |> expect_error L.Invalid_transition
;;

let test_cancel_cannot_undo_a_finished_task () =
  let done_status = D.Done { assignee = owner; completed_at = now; notes = None } in
  decide ~same_agent:true ~task_status:done_status ~action:D.Cancel ()
  |> expect_error L.Invalid_transition
;;

(* The verdict is where the two intents part. Same authority, same call, two
   terminals — and a rejection returns a cancellation to its producer exactly
   as it returns a completion. *)
let awaiting_with intent =
  D.AwaitingVerification
    { assignee = owner
    ; started_at = now
    ; submitted_at = now
    ; intent
    ; verification_id = "vrf-1"
    }
;;

let approve status =
  L.decide_verdict
    ~authority:(D.Human_operator { operator_id = "op-1" })
    ~verdict:D.Verdict_approved
    ~task_id:"task-1"
    ~verification_id:"vrf-1"
    ~task_status:status
    ~now
    ~notes:"operator's own note"
    ~read_cancellation_reason:producer_stated
;;

let test_approval_ends_the_task_the_way_it_was_asked () =
  (match approve (awaiting_with D.Complete_task) with
   | Ok { decision = { new_status = D.Done _; _ }; _ } -> ()
   | Ok _ | Error _ -> failwith "an approved completion must end as Done");
  match approve (awaiting_with D.Cancel_task) with
  | Ok { decision = { new_status = D.Cancelled { cancelled_by; reason; _ }; _ }; _ }
    when String.equal cancelled_by owner && reason = Some producer_reason -> ()
  | Ok _ | Error _ -> failwith "an approved cancellation must end as Cancelled"
;;

let test_a_rejected_cancellation_returns_to_its_producer () =
  match
    L.decide_verdict
      ~authority:(D.System_llm_agent { agent_run_id = "judge-run-cancel" })
      ~verdict:(D.Verdict_rejected { reason = "the task is still doable" })
      ~task_id:"task-1"
      ~verification_id:"vrf-1"
      ~task_status:(awaiting_with D.Cancel_task)
      ~now
      ~notes:""
      ~read_cancellation_reason:producer_stated
  with
  | Ok { decision = { new_status = D.InProgress { assignee; _ }; _ }; _ }
    when String.equal assignee owner -> ()
  | Ok _ | Error _ -> failwith "a refused cancellation must go back to the producer"
;;

let test_verification_preserves_original_start_time () =
  let original_started_at = "2026-07-12T23:45:00Z" in
  let submitted =
    match
      decide
        ~same_agent:true
        ~task_status:(D.InProgress { assignee = owner; started_at = original_started_at })
        ~action:D.Submit_for_verification
        ()
    with
    | Ok
        { new_status =
            D.AwaitingVerification { started_at; submitted_at; verification_id; _ }
        ; _
        }
      when String.equal started_at original_started_at
           && String.equal submitted_at now
           && String.equal verification_id "vrf-1" ->
      D.AwaitingVerification
        { assignee = owner; started_at; submitted_at; intent = Complete_task; verification_id }
    | Ok _ | Error _ -> failwith "submission must preserve the producer start time"
  in
  match
    L.decide_verdict
      ~authority:(D.System_llm_agent { agent_run_id = "judge-run-preserve-start" })
      ~verdict:(D.Verdict_rejected { reason = "missing evidence" })
      ~task_id:"task-1"
      ~verification_id:"vrf-1"
      ~task_status:submitted
      ~now:"2026-07-13T00:10:00Z"
      ~notes:""
      ~read_cancellation_reason:producer_stated
  with
  | Ok { decision = { new_status = D.InProgress { started_at; _ }; _ }; _ }
    when String.equal started_at original_started_at -> ()
  | Ok _ | Error _ -> failwith "rejection must restore the original producer start time"
;;

let test_awaiting_metrics_use_original_start_time () =
  let original_started_at = "2026-07-12T23:45:00Z" in
  let expected =
    match D.parse_iso8601_opt original_started_at with
    | Some timestamp -> timestamp
    | None -> failwith "test timestamp must be valid RFC 3339"
  in
  let actual =
    Workspace_task_classify.task_started_at_unix
      (D.AwaitingVerification
         { assignee = owner
         ; started_at = original_started_at
         ; submitted_at = "2026-07-13T00:00:00Z"
         ; intent = Complete_task
         ; verification_id = "vrf-metrics"
         })
  in
  match actual with
  | Some actual when Float.compare expected actual = 0 -> ()
  | Some _ | None -> failwith "awaiting metrics must use the original producer start time"
;;

(* #26575: a start that does not parse has no duration. It used to read as
   [now], so the completion metric reported a 0 ms task. *)
let test_unparsable_start_has_no_duration () =
  let unparsable = "not-a-timestamp" in
  List.iter
    (fun (label, status) ->
       match Workspace_task_classify.task_started_at_unix status with
       | None -> ()
       | Some _ -> failwith (label ^ ": an unparsable start must not yield a start time"))
    [ "claimed", D.Claimed { assignee = owner; claimed_at = unparsable }
    ; "in_progress", D.InProgress { assignee = owner; started_at = unparsable }
    ; ( "awaiting_verification"
      , D.AwaitingVerification
          { assignee = owner
          ; started_at = unparsable
          ; submitted_at = now
          ; intent = Complete_task
          ; verification_id = "vrf-unparsable"
          } )
    ]
;;

(* A start after [now] is a clock that ran backwards: it has no duration, not a
   zero one. A start at or before [now] measures from it. *)
let test_backwards_clock_has_no_duration () =
  match D.parse_iso8601_opt now with
  | None -> failwith "fixture timestamp must parse"
  | Some started_at ->
    let status = D.InProgress { assignee = owner; started_at = now } in
    (match Workspace_task_classify.task_duration_ms_since ~now:(started_at -. 1.0) status with
     | None -> ()
     | Some ms -> failwith (Printf.sprintf "a start after now must have no duration, got %dms" ms));
    (match Workspace_task_classify.task_duration_ms_since ~now:(started_at +. 2.0) status with
     | Some 2000 -> ()
     | Some ms -> failwith (Printf.sprintf "two seconds after the start must read 2000ms, got %dms" ms)
     | None -> failwith "a start before now must have a duration")
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

(* RFC-0417 §4.4: a cancel claim's terminal [Cancelled] record may carry only
   an operator's signature. The system lane's approval of a cancel claim is
   refused at the commit funnel itself, not merely at the review entrance. *)
let awaiting_cancel =
  D.AwaitingVerification
    { assignee = owner
    ; started_at = now
    ; submitted_at = now
    ; intent = Cancel_task
    ; verification_id = "vrf-1"
    }
;;

let test_system_approval_of_cancel_claim_is_refused () =
  match
    L.decide_verdict
      ~authority:(D.System_llm_agent { agent_run_id = "fusion-run-9" })
      ~verdict:D.Verdict_approved
      ~task_id:"task-1"
      ~verification_id:"vrf-1"
      ~task_status:awaiting_cancel
      ~now
      ~notes:"the upstream schema landed instead"
      ~read_cancellation_reason:producer_stated
  with
  | Error (L.Verdict_invalid L.Verdict_cancel_requires_operator) -> ()
  | Ok _ | Error _ ->
    failwith "a system signature must not end a cancel claim as Cancelled"
;;

(* The Cancelled record carries the producer's sentence. When the record that
   holds it cannot give one, the approval is refused instead of ending the
   Task with no reason or with the operator's notes in its place. *)
let test_approval_without_a_readable_reason_is_refused () =
  match
    L.decide_verdict
      ~authority:(D.Human_operator { operator_id = "op-1" })
      ~verdict:D.Verdict_approved
      ~task_id:"task-1"
      ~verification_id:"vrf-1"
      ~task_status:awaiting_cancel
      ~now
      ~notes:"operator's own note"
      ~read_cancellation_reason:(fun ~verification_id:_ ->
        Workspace_verification_store.Cancellation_reason_unreadable "no record")
  with
  | Error (L.Verdict_cancellation_reason_unreadable _) -> ()
  | Ok _ | Error _ ->
    failwith "an approved stop must not end without the producer's reason"
;;

let test_operator_approval_still_cancels_a_cancel_claim () =
  match
    L.decide_verdict
      ~authority:(D.Human_operator { operator_id = "op-1" })
      ~verdict:D.Verdict_approved
      ~task_id:"task-1"
      ~verification_id:"vrf-1"
      ~task_status:awaiting_cancel
      ~now
      ~notes:"the upstream schema landed instead"
      ~read_cancellation_reason:producer_stated
  with
  | Ok
      { decision = { new_status = D.Cancelled { cancelled_by; _ }; _ }
      ; authority = D.Human_operator { operator_id }
      ; _ }
    when String.equal cancelled_by owner && String.equal operator_id "op-1" ->
    ()
  | Ok _ | Error _ ->
    failwith "operator approval must still end a cancel claim as Cancelled"
;;

(* issue #32863 (comment 5530991457) records three dispositions the cancel lane
   has actually shown: an approval, a rejection, and the operator's own
   re-judgment. All three converge on the same commit funnel, so this drives
   each one through it on the same obligation -- a change that routes any of
   them through the wrong door fails here rather than in production. The
   operator-unanswered case is (3): with no operator signature the system
   lane's approval is refused and the claim is left where it was. *)
let test_contract4_three_judgements_of_a_cancel_claim () =
  let system = D.System_llm_agent { agent_run_id = "fusion-run-9" } in
  let operator = D.Human_operator { operator_id = "op-1" } in
  (* (1) rejection: the system lane may reject a cancel claim; the task returns
     to its producer with the reason carried. *)
  (match
     L.decide_verdict
       ~authority:system
       ~verdict:(D.Verdict_rejected { reason = "the upstream schema landed instead" })
       ~task_id:"task-1"
       ~verification_id:"vrf-1"
       ~task_status:awaiting_cancel
       ~now
       ~notes:"the upstream schema landed instead"
       ~read_cancellation_reason:producer_stated
   with
   | Ok
       { decision =
           { new_status = D.InProgress { assignee; _ }; set_current = Some id }
       ; authority = D.System_llm_agent _
       ; _
       }
     when String.equal assignee owner && String.equal id "task-1" -> ()
   | Ok _ | Error _ ->
     failwith
       "a reason-carrying rejection must return the cancel claim to its producer");
  (* (2) approval: only the operator's signature ends a cancel claim, and it
     ends it as Cancelled with the operator as authority. *)
  (match
     L.decide_verdict
       ~authority:operator
       ~verdict:D.Verdict_approved
       ~task_id:"task-1"
       ~verification_id:"vrf-1"
       ~task_status:awaiting_cancel
       ~now
       ~notes:"the operator withdrew the task"
       ~read_cancellation_reason:producer_stated
   with
   | Ok
       { decision = { new_status = D.Cancelled { cancelled_by; _ }; _ }
       ; authority = D.Human_operator { operator_id }
       ; _
       }
     when String.equal cancelled_by owner && String.equal operator_id "op-1" -> ()
   | Ok _ | Error _ ->
     failwith "an operator approval must end a cancel claim as Cancelled");
  (* (3) operator re-judgment / operator unanswered: the system lane cannot end
     it, so the operator's later verdict is the only path; with no operator
     signature the claim stays [AwaitingVerification] and the refusal is the
     seam the re-judgment sits behind. *)
  (match
     L.decide_verdict
       ~authority:system
       ~verdict:D.Verdict_approved
       ~task_id:"task-1"
       ~verification_id:"vrf-1"
       ~task_status:awaiting_cancel
       ~now
       ~notes:"the operator has not answered"
       ~read_cancellation_reason:producer_stated
   with
   | Error (L.Verdict_invalid L.Verdict_cancel_requires_operator) -> ()
   | Ok _ | Error _ ->
     failwith "a system signature must not pre-empt the operator re-judgment")
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
       ~read_cancellation_reason:producer_stated
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
       ~read_cancellation_reason:producer_stated
   with
   | Error (L.Verdict_invalid L.Verdict_rejection_reason_required) -> ()
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
       ~read_cancellation_reason:producer_stated
   with
   | Error (L.Verdict_invalid L.Verdict_authority_identity_required) -> ()
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
      ~read_cancellation_reason:producer_stated
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
      ~read_cancellation_reason:producer_stated
  with
  | Error (L.Verdict_invalid (L.Verification_id_mismatch { expected; actual }))
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
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
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
  test_done_has_no_non_verification_lane ();
  test_verification_preserves_original_start_time ();
  test_awaiting_metrics_use_original_start_time ();
  test_unparsable_start_has_no_duration ();
  test_backwards_clock_has_no_duration ();
  test_verdict_is_not_an_agent_action ();
  test_verdict_requires_authority_and_reason ();
  test_verdict_rejects_stale_verification_id ();
  test_claim_on_awaiting_is_refused ();
  test_awaiting_is_claimable_by_nobody ();
  test_holder_cancel_ends_the_task_at_once ();
  test_cancel_of_a_pending_submission_ends_the_task ();
  test_holder_cancel_requires_a_reason ();
  test_cancel_of_someone_elses_task_is_refused ();
  test_cancel_cannot_undo_a_finished_task ();
  test_approval_ends_the_task_the_way_it_was_asked ();
  test_a_rejected_cancellation_returns_to_its_producer ();
  test_contract4_three_judgements_of_a_cancel_claim ();
  test_system_approval_of_cancel_claim_is_refused ();
  test_operator_approval_still_cancels_a_cancel_claim ();
  test_approval_without_a_readable_reason_is_refused ();
  Printf.printf "workspace_task_lifecycle: all tests passed\n%!"
