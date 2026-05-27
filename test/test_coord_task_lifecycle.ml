(* Exhaustive coverage for [Coord_task_lifecycle.valid_next_actions].

   Each test pins the set of actions that [decide] accepts for one
   [task_status], cross-checked against the per-action [decide] result. The
   pair-of-truths ensures the enumerator never disagrees with the decider. *)

module L = Coord_task_lifecycle
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
    { assignee; submitted_at = now; verification_id = "v1"; deadline = None }
;;

let mk_done assignee =
  D.Done { assignee; completed_at = now; notes = None }
;;

let mk_cancelled cancelled_by =
  D.Cancelled { cancelled_by; cancelled_at = now; reason = None }
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
  | D.Submit_pr_evidence -> "submit_pr_evidence"
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

(* Cross-check: [valid_next_actions] returns exactly the [task_action]s for
   which [decide] returns [Ok], under the same caller context. *)
let assert_consistent_with_decide
      ~ctx
      ~verification_enabled
      ~same_agent
      ~force
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
        ~force
        ~notes:""
        ~reason:""
    with
    | Ok _ -> true
    | Error _ -> false
  in
  let expected = List.filter decide_says_ok D.all_task_actions in
  let actual =
    L.valid_next_actions ~verification_enabled ~same_agent ~force ~task_status
  in
  assert_actions ~ctx ~expected ~actual
;;

(* ── Per-status pinning tests (same_agent=true, force=false, verification on) ── *)

let test_todo () =
  (* Todo: Claim opens the lifecycle. Submit_pr_evidence is the only direct
     bypass into AwaitingVerification. Release is idempotent. Submit_for_verification
     emits Verification_disabled when verification_enabled=false, otherwise
     Invalid_transition — both are [Error]. Cancel from Todo is accepted. *)
  let task_status = D.Todo in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~force:false ~task_status
  in
  let expected = [ D.Claim; D.Cancel; D.Release; D.Submit_pr_evidence ] in
  assert_actions ~ctx:"todo" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"todo/consistency" ~verification_enabled:true
    ~same_agent:true ~force:false ~task_status
;;

let test_claimed_by_self () =
  let task_status = mk_claimed owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~force:false ~task_status
  in
  (* From Claimed by self: Claim (idempotent), Start, Done, Cancel,
     Release, Submit_for_verification. Submit_pr_evidence is Todo-only. *)
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
    ~same_agent:true ~force:false ~task_status
;;

let test_claimed_by_other () =
  let task_status = mk_claimed other in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:false ~force:false ~task_status
  in
  (* From Claimed by other (no force): all owner-gated actions reject. *)
  assert_actions ~ctx:"claimed-other" ~expected:[] ~actual;
  assert_consistent_with_decide
    ~ctx:"claimed-other/consistency" ~verification_enabled:true
    ~same_agent:false ~force:false ~task_status
;;

let test_claimed_by_other_with_force () =
  let task_status = mk_claimed other in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:false ~force:true ~task_status
  in
  (* Force unlocks Start / Done / Cancel / Release for non-owners. Claim still
     requires same_agent (no force in decide for Claim). *)
  let expected = [ D.Start; D.Done_action; D.Cancel; D.Release ] in
  assert_actions ~ctx:"claimed-other-force" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"claimed-other-force/consistency" ~verification_enabled:true
    ~same_agent:false ~force:true ~task_status
;;

let test_in_progress_self () =
  let task_status = mk_in_progress owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~force:false ~task_status
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
    ~same_agent:true ~force:false ~task_status
;;

let test_awaiting_verification_by_other () =
  let task_status = mk_awaiting other in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:false ~force:false ~task_status
  in
  (* Approver path: same_agent=false (not the submitter) → Approve / Reject ok. *)
  let expected = [ D.Approve_verification; D.Reject_verification ] in
  assert_actions ~ctx:"awaiting-by-other" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"awaiting-by-other/consistency" ~verification_enabled:true
    ~same_agent:false ~force:false ~task_status
;;

let test_awaiting_verification_by_submitter () =
  let task_status = mk_awaiting owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~force:false ~task_status
  in
  (* Same agent as submitter → Self_approval / Self_rejection blocks both. *)
  assert_actions ~ctx:"awaiting-by-submitter" ~expected:[] ~actual;
  assert_consistent_with_decide
    ~ctx:"awaiting-by-submitter/consistency" ~verification_enabled:true
    ~same_agent:true ~force:false ~task_status
;;

let test_done () =
  let task_status = mk_done owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~force:false ~task_status
  in
  (* Done is terminal except for idempotent Claim / Start / Done_action which
     return the same status (decide returns Ok without state change). *)
  let expected = [ D.Claim; D.Start; D.Done_action ] in
  assert_actions ~ctx:"done" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"done/consistency" ~verification_enabled:true
    ~same_agent:true ~force:false ~task_status
;;

let test_cancelled () =
  let task_status = mk_cancelled owner in
  let actual =
    L.valid_next_actions
      ~verification_enabled:true ~same_agent:true ~force:false ~task_status
  in
  (* Cancelled idempotent on Cancel only. *)
  let expected = [ D.Cancel ] in
  assert_actions ~ctx:"cancelled" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"cancelled/consistency" ~verification_enabled:true
    ~same_agent:true ~force:false ~task_status
;;

let test_verification_disabled_todo () =
  (* When verification is disabled, Submit_for_verification and approval
     actions emit Verification_disabled — still [Error], so excluded. *)
  let task_status = D.Todo in
  let actual =
    L.valid_next_actions
      ~verification_enabled:false ~same_agent:true ~force:false ~task_status
  in
  let expected = [ D.Claim; D.Cancel; D.Release ] in
  (* Note: Submit_pr_evidence under verification_disabled returns
     Verification_disabled too — excluded compared to test_todo. *)
  assert_actions ~ctx:"todo-verification-disabled" ~expected ~actual;
  assert_consistent_with_decide
    ~ctx:"todo-verification-disabled/consistency" ~verification_enabled:false
    ~same_agent:true ~force:false ~task_status
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
                        ~ctx ~verification_enabled ~same_agent ~force ~task_status)
                   bools)
              bools)
         bools)
    statuses
;;

(* ── required_tools inference from write-intent keywords ──── *)

module Classify = Coord_task_classify

let assert_equal_string_list ~ctx ~expected ~actual =
  if expected <> actual
  then (
    Printf.printf
      "FAIL [%s]\n  expected: [%s]\n  actual:   [%s]\n%!"
      ctx
      (String.concat "; " expected)
      (String.concat "; " actual);
    exit 1)
;;

let test_write_intent_detected () =
  let contract =
    Classify.ensure_task_contract_for_verification
      ~title:"Fix the authentication bug"
      ~description:"The login flow needs to be updated"
      ()
  in
  assert_equal_string_list
    ~ctx:"write-intent: fix+update detected"
    ~expected:[ "keeper_fs_edit"; "tool_execute" ]
    ~actual:contract.required_tools
;;

let test_write_intent_korean () =
  let contract =
    Classify.ensure_task_contract_for_verification
      ~title:"로그인 버그 수정"
      ~description:"인증 흐름을 변경해야 합니다"
      ()
  in
  assert_equal_string_list
    ~ctx:"write-intent: Korean 수정+변경 detected"
    ~expected:[ "keeper_fs_edit"; "tool_execute" ]
    ~actual:contract.required_tools
;;

let test_write_intent_pr () =
  let contract =
    Classify.ensure_task_contract_for_verification
      ~title:"Create PR for feature X"
      ~description:"Submit pull request with new dashboard"
      ()
  in
  assert_equal_string_list
    ~ctx:"write-intent: PR detected"
    ~expected:[ "keeper_fs_edit"; "tool_execute" ]
    ~actual:contract.required_tools
;;

let test_no_write_intent () =
  let contract =
    Classify.ensure_task_contract_for_verification
      ~title:"Analyze system performance"
      ~description:"Review current metrics and report findings"
      ()
  in
  assert_equal_string_list
    ~ctx:"no write-intent: analyze+review"
    ~expected:[]
    ~actual:contract.required_tools
;;

let test_explicit_required_tools_preserved () =
  let explicit_contract =
    { Classify.empty_task_contract with required_tools = [ "custom_tool"; "another_tool" ] }
  in
  let contract =
    Classify.ensure_task_contract_for_verification
      ~contract:explicit_contract
      ~title:"Fix the bug"
      ~description:"This should not override"
      ()
  in
  assert_equal_string_list
    ~ctx:"explicit required_tools preserved"
    ~expected:[ "custom_tool"; "another_tool" ]
    ~actual:contract.required_tools
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
  test_write_intent_detected ();
  test_write_intent_korean ();
  test_write_intent_pr ();
  test_no_write_intent ();
  test_explicit_required_tools_preserved ();
  print_endline "test_coord_task_lifecycle: all assertions passed"
;;
