module L = Workspace_task_lifecycle
module D = Masc_domain

let owner = "alice"
let now = "2026-07-13T00:00:00Z"

let decide
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

(* Cancel had no test of its own. It now answers the way Done does: a
   producer submits the stop and waits for a verdict, and the same verdict
   path ends the Task as Cancelled rather than Done because the obligation
   records which question was asked. *)
let awaiting_cancel = function
  | Ok { L.new_status = D.AwaitingVerification { intent = D.Cancel_task; verification_id; _ }; _ } ->
    verification_id
  | Ok { L.new_status = D.AwaitingVerification { intent = D.Complete_task; _ }; _ } ->
    failwith "cancel submitted as a completion"
  | Ok _ -> failwith "cancel did not wait for a verdict"
  | Error _ -> failwith "cancel was refused"
;;

let test_cancel_waits_for_a_verdict_like_done_does () =
  let vrf = awaiting_cancel (decide ~same_agent:true ~task_status:in_progress ~action:D.Cancel ()) in
  if not (String.equal vrf "vrf-1") then failwith "cancel must mint a verification id";
  (* Neither terminal is reachable alone from the same state. *)
  decide ~same_agent:true ~task_status:in_progress ~action:D.Done_action ()
  |> expect_error L.Verification_submission_required
;;

let test_cancel_of_someone_elses_task_is_refused () =
  decide ~same_agent:false ~task_status:in_progress ~action:D.Cancel ()
  |> expect_error L.Invalid_transition;
  decide ~same_agent:false ~task_status:awaiting ~action:D.Cancel ()
  |> expect_error L.Invalid_transition
;;

(* A stop asked for while a submission is pending supersedes it. Ending the
   Task here would let submit-then-cancel reach a terminal state alone.

   The pending status is built here rather than reusing [awaiting] because the
   shared fixture carries [started_at = now] and [verification_id = "vrf-1"],
   which are the same values the transition would produce if it preserved
   neither: both assertions would hold for code that restated the start time
   and reused the old id. These two differ from what the transition mints. *)
let test_cancel_of_a_pending_submission_waits_for_a_verdict () =
  let began = "2026-07-12T00:00:00Z" in
  let pending =
    D.AwaitingVerification
      { assignee = owner
      ; started_at = began
      ; submitted_at = now
      ; intent = D.Complete_task
      ; verification_id = "vrf-0"
      }
  in
  match decide ~same_agent:true ~task_status:pending ~action:D.Cancel () with
  | Ok
      { L.new_status =
          D.AwaitingVerification
            { intent = D.Cancel_task; started_at; verification_id; _ }
      ; _
      } ->
    if not (String.equal started_at began)
    then failwith "the work began once; a stop must not restate when";
    if String.equal verification_id "vrf-0"
    then failwith "a superseding stop must mint its own verification id"
  | Ok { L.new_status = D.Cancelled _; _ } ->
    failwith "a pending submission was cancelled without a verdict"
  | Ok _ | Error _ -> failwith "cancel of a pending submission must wait for a verdict"
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
    ~notes:"the premise no longer holds"
;;

let test_approval_ends_the_task_the_way_it_was_asked () =
  (match approve (awaiting_with D.Complete_task) with
   | Ok { decision = { new_status = D.Done _; _ }; _ } -> ()
   | Ok _ | Error _ -> failwith "an approved completion must end as Done");
  match approve (awaiting_with D.Cancel_task) with
  | Ok { decision = { new_status = D.Cancelled { cancelled_by; reason; _ }; _ }; _ }
    when String.equal cancelled_by owner
         && reason = Some "the premise no longer holds" -> ()
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
  if Float.compare expected actual <> 0
  then failwith "awaiting metrics must use the original producer start time"
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
  test_verdict_is_not_an_agent_action ();
  test_verdict_requires_authority_and_reason ();
  test_verdict_rejects_stale_verification_id ();
  test_claim_on_awaiting_is_refused ();
  test_awaiting_is_claimable_by_nobody ();
  test_cancel_waits_for_a_verdict_like_done_does ();
  test_cancel_of_someone_elses_task_is_refused ();
  test_cancel_of_a_pending_submission_waits_for_a_verdict ();
  test_cancel_cannot_undo_a_finished_task ();
  test_approval_ends_the_task_the_way_it_was_asked ();
  test_a_rejected_cancellation_returns_to_its_producer ();
  Printf.printf "workspace_task_lifecycle: all tests passed\n%!"
