(* Exhaustive coverage for [Workspace_task_lifecycle.valid_next_actions].

   Each test pins the set of actions that [decide] accepts for one
   [task_status], cross-checked against the per-action [decide] result. The
   pair-of-truths ensures the enumerator never disagrees with the decider. *)

module L = Workspace_task_lifecycle
module D = Masc_domain

let owner = "alice"
let other = "bob"
let now = "2026-05-21T19:00:00Z"

let mk_claimed assignee =
  D.Claimed { assignee; claimed_at = now }
;;

let mk_in_progress assignee =
  D.InProgress { assignee; started_at = now }
;;

let mk_awaiting assignee =
  D.AwaitingVerification
    { assignee; submitted_at = now; verification_id = "v1"; phase = Awaiting_verifier }
;;

let mk_done assignee =
  D.Done { assignee; completed_at = now; notes = None }
;;

let mk_cancelled cancelled_by =
  D.Cancelled { cancelled_by; cancelled_at = now; reason = None }
;;

let mk_task ?reclaim_policy status =
  { D.id = "task-claim"
  ; title = "claim lifecycle task"
  ; description = ""
  ; task_status = status
  ; priority = 1
  ; files = []
  ; created_at = now
  ; created_by = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy
  ; do_not_reclaim_reason = None
  }
;;

let action_to_string = function
  | D.Claim -> "claim"
  | D.Start -> "start"
  | D.Done_action -> "done"
  | D.Cancel -> "cancel"
  | D.Release -> "release"
  | D.Submit_for_verification -> "submit_for_verification"
  | D.Approve_verification -> "approve"
  | D.Reject_verification -> "reject"
;;

let sort_actions xs =
  List.sort (fun a b -> String.compare (action_to_string a) (action_to_string b)) xs
;;

let actions_equal xs ys =
  let xs = sort_actions xs in
  let ys = sort_actions ys in
  List.length xs = List.length ys
  && List.for_all2 (fun a b -> action_to_string a = action_to_string b) xs ys
;;

let assert_actions ~ctx ~expected ~actual =
  if not (actions_equal expected actual)
  then (
    let render xs =
      xs |> sort_actions |> List.map action_to_string |> String.concat ","
    in
    Printf.printf
      "FAIL [%s]\n  expected: [%s]\n  actual:   [%s]\n%!"
      ctx
      (render expected)
      (render actual);
    exit 1)
;;

let fail msg =
  Printf.printf "FAIL %s\n%!" msg;
  exit 1
;;

let decide_claim ~same_agent ~agent_name ~task_id ~task_status =
  L.decide
    ~verification_enabled:true
    ~verification_timeout_seconds:0.0
    ~new_verification_id:(fun () -> "vrf-new")
    ~same_agent
    ~agent_name
    ~task_id
    ~task_status
    ~action:D.Claim
    ~now
    ~authority:D.Assignee
    ~notes:""
    ~reason:""
;;

(* Cross-check: [valid_next_actions] returns exactly the [task_action]s for
   which [decide] returns [Ok], under the same caller context. *)
let assert_consistent_with_decide
      ~ctx
      ~verification_enabled
      ~same_agent
      ~authority
      ~task_status
  =
  let same_agent_pred _ = same_agent in
  let decide_says_ok action =
    match
      L.decide
        ~verification_enabled
        ~verification_timeout_seconds:0.0
        ~new_verification_id:(fun () -> "")
        ~same_agent:same_agent_pred
        ~agent_name:""
        ~task_id:""
        ~task_status
        ~action
        ~now:""
        ~authority
        ~notes:""
        ~reason:""
    with
    | Ok _ -> true
    | Error _ -> false
  in
  let expected = List.filter decide_says_ok D.all_task_actions in
  let actual =
    L.valid_next_actions ~verification_enabled ~same_agent ~authority ~task_status
  in
  assert_actions ~ctx ~expected ~actual
;;

(* ── Per-status pinning tests (same_agent=true, force=false, verification on) ── *)

let test_todo () =
  (* Todo: Claim opens the lifecycle. Release is idempotent.
     Submit_for_verification emits Verification_disabled when
     verification_enabled=false, otherwise Invalid_transition — both
     are [Error]. Cancel from Todo is accepted. *)
  let task_status = D.Todo in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~authority:D.Assignee ~task_status
  in
  let expected = [ D.Claim; D.Cancel; D.Release ] in
  assert_actions ~ctx:"todo" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"todo/consistency" ~verification_enabled:true
    ~same_agent:true ~authority:D.Assignee ~task_status
;;

let test_claimed_by_self () =
  let task_status = mk_claimed owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~authority:D.Assignee ~task_status
  in
  (* From Claimed by self: Claim (idempotent), Start, Done, Cancel,
     Release, Submit_for_verification. *)
  let expected =
    [ D.Claim
    ; D.Start
    ; D.Done_action
    ; D.Cancel
    ; D.Release
    ; D.Submit_for_verification
    ]
  in
  assert_actions ~ctx:"claimed-self" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"claimed-self/consistency" ~verification_enabled:true
    ~same_agent:true ~authority:D.Assignee ~task_status
;;

let test_claimed_by_other () =
  let task_status = mk_claimed other in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:false ~authority:D.Assignee ~task_status
  in
  (* From Claimed by other (no force): all owner-gated actions reject. *)
  assert_actions ~ctx:"claimed-other" ~expected:[] ~actual;
  assert_consistent_with_decide
    ~ctx:"claimed-other/consistency" ~verification_enabled:true
    ~same_agent:false ~authority:D.Assignee ~task_status
;;

let test_claimed_by_other_with_force () =
  let task_status = mk_claimed other in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:false ~authority:D.Operator ~task_status
  in
  (* Force unlocks Start / Done / Cancel / Release for non-owners. Claim still
     requires same_agent (no force in decide for Claim). *)
  let expected = [ D.Start; D.Done_action; D.Cancel; D.Release ] in
  assert_actions ~ctx:"claimed-other-force" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"claimed-other-force/consistency" ~verification_enabled:true
    ~same_agent:false ~authority:D.Operator ~task_status
;;

let test_in_progress_self () =
  let task_status = mk_in_progress owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~authority:D.Assignee ~task_status
  in
  let expected =
    [ D.Claim
    ; D.Start
    ; D.Done_action
    ; D.Cancel
    ; D.Release
    ; D.Submit_for_verification
    ]
  in
  assert_actions ~ctx:"in_progress-self" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"in_progress-self/consistency" ~verification_enabled:true
    ~same_agent:true ~authority:D.Assignee ~task_status
;;

let test_awaiting_verification_by_other () =
  let task_status = mk_awaiting other in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:false ~authority:D.Assignee ~task_status
  in
  (* same_agent=false (not the submitter): a verifier may Approve / Reject, and
     may also Claim the task to verify it (cross-agent verification dispatch,
     Issue #19314 / RFC-0220 §3.5). The prior expectation predated #19314's
     cross-agent Claim arm in [decide]; align it with the actual behavior. *)
  let expected = [ D.Claim; D.Approve_verification; D.Reject_verification ] in
  assert_actions ~ctx:"awaiting-by-other" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"awaiting-by-other/consistency" ~verification_enabled:true
    ~same_agent:false ~authority:D.Assignee ~task_status
;;

let test_awaiting_verification_by_submitter () =
  let task_status = mk_awaiting owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~authority:D.Assignee ~task_status
  in
  (* Same agent as submitter → Self_approval / Self_rejection blocks both. *)
  assert_actions ~ctx:"awaiting-by-submitter" ~expected:[] ~actual;
  assert_consistent_with_decide
    ~ctx:"awaiting-by-submitter/consistency" ~verification_enabled:true
    ~same_agent:true ~authority:D.Assignee ~task_status
;;

let test_done () =
  let task_status = mk_done owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~authority:D.Assignee ~task_status
  in
  (* Done is terminal except for idempotent Claim / Start / Done_action which
     return the same status (decide returns Ok without state change). *)
  let expected = [ D.Claim; D.Start; D.Done_action ] in
  assert_actions ~ctx:"done" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"done/consistency" ~verification_enabled:true
    ~same_agent:true ~authority:D.Assignee ~task_status
;;

let test_cancelled () =
  let task_status = mk_cancelled owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~authority:D.Assignee ~task_status
  in
  (* Cancelled idempotent on Cancel only. *)
  let expected = [ D.Cancel ] in
  assert_actions ~ctx:"cancelled" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"cancelled/consistency" ~verification_enabled:true
    ~same_agent:true ~authority:D.Assignee ~task_status
;;

let test_verification_disabled_todo () =
  (* When verification is disabled, Submit_for_verification and approval
     actions emit Verification_disabled — still [Error], so excluded. *)
  let task_status = D.Todo in
  let actual =
    L.valid_next_actions
      ~verification_enabled:false ~same_agent:true ~authority:D.Assignee ~task_status
  in
  let expected = [ D.Claim; D.Cancel; D.Release ] in
  assert_actions ~ctx:"todo-verification-disabled" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"todo-verification-disabled/consistency" ~verification_enabled:false
    ~same_agent:true ~authority:D.Assignee ~task_status
;;

(* Exhaustive consistency sweep — every (task_status × same_agent × force ×
   verification_enabled) combination must satisfy the cross-check. Pins the
   invariant: valid_next_actions ≡ filter decide. *)
let test_exhaustive_consistency () =
  let statuses =
    [ D.Todo
    ; mk_claimed owner
    ; mk_claimed other
    ; mk_in_progress owner
    ; mk_in_progress other
    ; mk_awaiting owner
    ; mk_awaiting other
    ; mk_done owner
    ; mk_cancelled owner
    ]
  in
  let bools = [ true; false ] in
  List.iter
    (fun task_status ->
       List.iter
         (fun verification_enabled ->
            List.iter
              (fun same_agent ->
                 List.iter
                   (fun force ->
                      let ctx =
                        Printf.sprintf
                          "ve=%b/sa=%b/f=%b/status=%s"
                          verification_enabled
                          same_agent
                          force
                          (D.task_status_to_string task_status)
                      in
                      assert_consistent_with_decide
                        ~ctx ~verification_enabled ~same_agent
                        ~authority:(if force then D.Operator else D.Assignee)
                        ~task_status)
                   bools)
              bools)
         bools)
    statuses
;;

(* ── RFC-0220 §3.5: cross-agent claim binds the verifier ───── *)

(* A verifier (not the submitter) claiming an [AwaitingVerification] obligation
   preserves the obligation and records the claimer in [phase] —
   [Verifier_assigned] — with [set_current] pointing the verifier at the task.
   The status is NOT clobbered to [Claimed]; the submitter is preserved as
   [assignee]. This is the satisfier binding that the auto-claim path also
   reuses via [resolve_claim]. *)
let test_claim_awaiting_binds_verifier () =
  match
    decide_claim
      ~same_agent:(fun a -> String.equal a "verifier-x")
      ~agent_name:"verifier-x"
      ~task_id:"task-1"
      ~task_status:(mk_awaiting other)
  with
  | Ok
      { L.new_status =
          D.AwaitingVerification { phase = D.Verifier_assigned { verifier }; assignee; _ }
      ; set_current
      ; _
      } ->
    if not (String.equal verifier "verifier-x") then fail "verifier not bound to the claimer";
    if not (String.equal assignee other) then fail "submitter (assignee) must be preserved";
    (match set_current with
     | Some t when String.equal t "task-1" -> ()
     | _ -> fail "cross-agent claim must point the verifier at the task (set_current)")
  | Ok { L.new_status; _ } ->
    fail
      (Printf.sprintf
         "expected AwaitingVerification/Verifier_assigned, got %s"
         (D.task_status_to_string new_status))
  | Error _ -> fail "cross-agent claim of AwaitingVerification must be accepted"
;;

(* The submitter cannot claim (self-verify) their own obligation. *)
let test_claim_awaiting_by_self_blocked () =
  match
    decide_claim
      ~same_agent:(fun a -> String.equal a owner)
      ~agent_name:owner
      ~task_id:"task-2"
      ~task_status:(mk_awaiting owner)
  with
  | Error _ -> ()
  | Ok _ -> fail "submitter must not claim (self-verify) their own AwaitingVerification"
;;

(* [resolve_claim] is the single claim decision shared by both writers. Pin the
   worker, verifier, self-block, held-by-other, and typed reclaim-block outcomes. *)
let test_resolve_claim_outcomes () =
  let actor x a = String.equal a x in
  (match L.resolve_claim ~same_actor:(actor "w") ~agent_name:"w" ~now (mk_task D.Todo) with
   | L.Worker_claim (D.Claimed { assignee = "w"; _ }) -> ()
   | _ -> fail "Todo should resolve to Worker_claim Claimed");
  (match
     L.resolve_claim ~same_actor:(actor "v") ~agent_name:"v" ~now
       (mk_task (mk_awaiting other))
   with
   | L.Verifier_claim
       (D.AwaitingVerification { phase = D.Verifier_assigned { verifier = "v" }; assignee; _ })
     when String.equal assignee other -> ()
   | _ -> fail "cross-agent AwaitingVerification should resolve to Verifier_claim (verifier bound, submitter preserved)");
  (match
     L.resolve_claim ~same_actor:(actor other) ~agent_name:other ~now
       (mk_task (mk_awaiting other))
   with
   | L.Self_owned -> ()
   | _ -> fail "own AwaitingVerification should resolve to Self_owned (the self-block)");
  (match
     L.resolve_claim ~same_actor:(actor "z") ~agent_name:"z" ~now
       (mk_task (mk_claimed other))
   with
   | L.Held_by_other h when String.equal h other -> ()
   | _ -> fail "Claimed-by-other should resolve to Held_by_other naming the holder");
  (match
     L.resolve_claim ~same_actor:(actor "w") ~agent_name:"w" ~now
       (mk_task (mk_done other))
   with
   | L.Held_by_other h when String.equal h other -> ()
   | _ -> fail "Done without explicit Allow_reclaim should stay held/terminal");
  (match
     L.resolve_claim ~same_actor:(actor "w") ~agent_name:"w" ~now
       (mk_task ~reclaim_policy:D.Allow_reclaim (mk_done other))
   with
   | L.Worker_claim (D.Claimed { assignee = "w"; _ }) -> ()
   | _ -> fail "Done with Allow_reclaim should resolve to Worker_claim Claimed");
  (* Self-livelock guard: the completer must not reclaim its own Done task, even
     with Allow_reclaim — that busy-loops complete -> reclaim. Only a different
     actor may reclaim (asserted above). *)
  (match
     L.resolve_claim ~same_actor:(actor other) ~agent_name:other ~now
       (mk_task ~reclaim_policy:D.Allow_reclaim (mk_done other))
   with
   | L.Self_owned -> ()
   | _ -> fail "own Done+Allow_reclaim must resolve to Self_owned (self-livelock guard)");
  match
    L.resolve_claim ~same_actor:(actor "w") ~agent_name:"w" ~now
      (mk_task ~reclaim_policy:D.Block_reclaim (mk_done other))
  with
  | L.Blocked_by_reclaim_policy _ -> ()
  | _ -> fail "Done with Block_reclaim should resolve to Blocked_by_reclaim_policy"
;;

(* [Verifier_assigned] must survive a serialize -> parse round-trip so the
   satisfier binding is durable across backlog writes. *)
let test_verifier_assigned_codec_roundtrip () =
  let status =
    D.bind_verifier ~verifier:"v" ~assignee:other ~submitted_at:now ~verification_id:"vrf-1"
  in
  match D.task_status_of_yojson (D.task_status_to_yojson status) with
  | Ok
      (D.AwaitingVerification
        { phase = D.Verifier_assigned { verifier = "v" }; verification_id = "vrf-1"; assignee; _ })
    when String.equal assignee other -> ()
  | _ -> fail "Verifier_assigned must round-trip through the task_status codec"
;;

(* ── runner ───────────────────────────────────────────────── *)

let () =
  test_todo ();
  test_claimed_by_self ();
  test_claimed_by_other ();
  test_claimed_by_other_with_force ();
  test_in_progress_self ();
  test_awaiting_verification_by_other ();
  test_awaiting_verification_by_submitter ();
  test_done ();
  test_cancelled ();
  test_verification_disabled_todo ();
  test_exhaustive_consistency ();
  test_claim_awaiting_binds_verifier ();
  test_claim_awaiting_by_self_blocked ();
  test_resolve_claim_outcomes ();
  test_verifier_assigned_codec_roundtrip ();
  print_endline "test_task_state_lifecycle: all assertions passed"
;;
