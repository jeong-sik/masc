(** Tests for Completion_trust_audit — the RFC-0262 §9 metric fold.

    Structured as a TLA+ bug-model pairing at the log level: a *clean* event
    stream must produce zero §9① violations (PASS), and a stream with a planted
    foreign completion must be *caught* (FAIL). If the planted-violation test
    ever passes with [foreign=0], the auditor has stopped detecting the very bug
    RFC-0262 closed. *)

module A = Completion_trust_audit

let claimed ~task ~agent =
  `Assoc
    [ "type", `String "task_transition"
    ; "agent", `String agent
    ; "task", `String task
    ; "to_status", `String "claimed"
    ; "action", `String "claim"
    ]
;;

let done_ev ?authority ?assignee ?(forced = false) ?(from_status = "in_progress") ~task ~agent
  ()
  =
  `Assoc
    ([ "type", `String "task_transition"
     ; "agent", `String agent
     ; "task", `String task
     ; "from_status", `String from_status
     ; "to_status", `String "done"
     ; "action", `String (if from_status = "awaiting_verification" then "approve" else "done")
     ; "forced", `Bool forced
     ; "ts", `String "2026-06-19T00:00:00Z"
     ]
     @ (match authority with Some a -> [ "authority", `String a ] | None -> [])
     @ (match assignee with Some a -> [ "assignee", `String a ] | None -> []))
;;

(* ---- clean stream: every completion is a legitimate self-completion ---- *)

let clean_log =
  [ claimed ~task:"A" ~agent:"alice"
  ; done_ev ~authority:"assignee" ~task:"A" ~agent:"alice" ()
  ; claimed ~task:"B" ~agent:"bob"
  ; done_ev ~authority:"assignee" ~task:"B" ~agent:"bob" ()
  ]
;;

let test_clean_log_passes () =
  let m = A.audit_events clean_log in
  Alcotest.(check int) "two completions" 2 m.A.done_total;
  Alcotest.(check int) "all assignee" 2 m.A.done_assignee;
  Alcotest.(check int)
    "no foreign violations"
    0
    (List.length m.A.foreign_assignee_completions);
  Alcotest.(check int) "no force-equivalent" 0 m.A.force_equivalent_completions;
  Alcotest.(check int) "no indeterminate" 0 m.A.indeterminate_ownership
;;

(* ---- planted stream: foreign self-claim completions must be caught ---- *)

let planted_log =
  [ (* legit self-completion *)
    claimed ~task:"A" ~agent:"alice"
  ; done_ev ~authority:"assignee" ~task:"A" ~agent:"alice" ()
  ; (* PLANTED §9① violation: bob claims, carol completes with assignee authority *)
    claimed ~task:"B" ~agent:"bob"
  ; done_ev ~authority:"assignee" ~task:"B" ~agent:"carol" ()
  ; (* legit operator override on a foreign task (not a §9① violation) *)
    claimed ~task:"C" ~agent:"dave"
  ; done_ev ~authority:"operator" ~task:"C" ~agent:"ops" ()
  ; (* legit system code-path completion on a foreign task *)
    claimed ~task:"D" ~agent:"erin"
  ; done_ev ~authority:"system" ~task:"D" ~agent:"probe" ()
  ; (* PLANTED legacy §9① violation: no authority field, forced=false, foreign *)
    claimed ~task:"E" ~agent:"frank"
  ; done_ev ~task:"E" ~agent:"grace" ()
  ; (* legacy forced override (legacy_forced -> force-equivalent, legit) *)
    claimed ~task:"F" ~agent:"heidi"
  ; done_ev ~forced:true ~task:"F" ~agent:"ops" ()
  ; (* indeterminate: assignee-authority completion with no preceding claim *)
    done_ev ~authority:"assignee" ~task:"G" ~agent:"ivan" ()
  ; (* legitimate cross-agent verification approval: judy claims, the bound
       verifier (≠ assignee, by FSM design) approves from awaiting_verification.
       NOT a §9① foreign completion — this is the live-log over-count we fixed. *)
    claimed ~task:"H" ~agent:"judy"
  ; done_ev ~from_status:"awaiting_verification" ~task:"H" ~agent:"verifier-keeper" ()
  ; (* malformed line *)
    `String "garbage"
  ]
;;

let test_planted_violations_caught () =
  let m = A.audit_events planted_log in
  Alcotest.(check int) "eight completions" 8 m.A.done_total;
  Alcotest.(check int) "one verification approval, not foreign" 1 m.A.verification_approvals;
  Alcotest.(check int)
    "two foreign self-claim violations caught"
    2
    (List.length m.A.foreign_assignee_completions);
  (* the violations are B/carol and E/grace, in chronological order *)
  (match m.A.foreign_assignee_completions with
   | [ first; second ] ->
     Alcotest.(check string) "first violation task" "B" first.A.task_id;
     Alcotest.(check string) "first violation actor" "carol" first.A.actor;
     Alcotest.(check string) "first violation owner" "bob"
       (Option.value first.A.assignee ~default:"?");
     Alcotest.(check string) "second violation task" "E" second.A.task_id;
     Alcotest.(check string) "second violation actor" "grace" second.A.actor
   | other ->
     Alcotest.failf "expected 2 violations, got %d" (List.length other));
  Alcotest.(check int)
    "force-equivalent: operator + system + legacy_forced"
    3
    m.A.force_equivalent_completions;
  Alcotest.(check int) "one indeterminate" 1 m.A.indeterminate_ownership;
  Alcotest.(check int) "one malformed line skipped" 1 m.A.events_skipped
;;

(* ---- force-equivalent foreign completions are legitimate, not violations ---- *)

let test_force_equivalent_not_flagged () =
  let log =
    [ claimed ~task:"X" ~agent:"owner"
    ; done_ev ~authority:"operator" ~task:"X" ~agent:"someone_else" ()
    ; claimed ~task:"Y" ~agent:"owner2"
    ; done_ev ~authority:"system" ~task:"Y" ~agent:"probe" ()
    ]
  in
  let m = A.audit_events log in
  Alcotest.(check int)
    "no §9① violation for operator/system foreign"
    0
    (List.length m.A.foreign_assignee_completions);
  Alcotest.(check int) "both force-equivalent" 2 m.A.force_equivalent_completions
;;

(* ---- unknown authority label surfaces explicitly, never as a violation ---- *)

let test_unknown_authority_bucketed () =
  let log =
    [ claimed ~task:"Z" ~agent:"owner"
    ; done_ev ~authority:"superuser" ~task:"Z" ~agent:"someone_else" ()
    ]
  in
  let m = A.audit_events log in
  Alcotest.(check int) "unknown authority counted" 1 m.A.done_unknown_authority;
  Alcotest.(check int)
    "unknown is not a §9① violation"
    0
    (List.length m.A.foreign_assignee_completions);
  Alcotest.(check int)
    "unknown is not force-equivalent"
    0
    m.A.force_equivalent_completions
;;

(* ---- a verifier completing from awaiting_verification is never foreign ---- *)

let test_verification_approval_not_foreign () =
  let log =
    [ claimed ~task:"V" ~agent:"submitter"
    ; done_ev ~from_status:"awaiting_verification" ~task:"V" ~agent:"a_different_verifier" ()
    ]
  in
  let m = A.audit_events log in
  Alcotest.(check int)
    "verifier approval not counted as §9① foreign"
    0
    (List.length m.A.foreign_assignee_completions);
  Alcotest.(check int) "counted as a verification approval" 1 m.A.verification_approvals;
  Alcotest.(check int) "no indeterminate" 0 m.A.indeterminate_ownership
;;

(* ---- logged assignee: foreign caught directly, no claim reconstruction ---- *)

let test_logged_assignee_direct () =
  (* No claim events at all — ownership comes purely from the logged assignee
     field. The §9 assignee logging removes the out-of-window blind spot. *)
  let log =
    [ done_ev ~authority:"assignee" ~assignee:"real_owner" ~task:"P" ~agent:"intruder" ()
    ; done_ev ~authority:"assignee" ~assignee:"self" ~task:"Q" ~agent:"self" ()
    ]
  in
  let m = A.audit_events log in
  Alcotest.(check int)
    "foreign caught from logged assignee without any claim event"
    1
    (List.length m.A.foreign_assignee_completions);
  Alcotest.(check int)
    "logged assignee is never indeterminate"
    0
    m.A.indeterminate_ownership;
  match m.A.foreign_assignee_completions with
  | [ r ] ->
    Alcotest.(check string) "violation task" "P" r.A.task_id;
    Alcotest.(check string) "violation owner" "real_owner"
      (Option.value r.A.assignee ~default:"?")
  | other -> Alcotest.failf "expected 1, got %d" (List.length other)
;;

let () =
  Alcotest.run
    "completion_trust_audit"
    [ ( "section_9"
      , [ Alcotest.test_case "clean log passes" `Quick test_clean_log_passes
        ; Alcotest.test_case
            "logged assignee direct measurement"
            `Quick
            test_logged_assignee_direct
        ; Alcotest.test_case
            "planted violations caught"
            `Quick
            test_planted_violations_caught
        ; Alcotest.test_case
            "force-equivalent not flagged"
            `Quick
            test_force_equivalent_not_flagged
        ; Alcotest.test_case
            "verification approval not foreign"
            `Quick
            test_verification_approval_not_foreign
        ; Alcotest.test_case
            "unknown authority bucketed"
            `Quick
            test_unknown_authority_bucketed
        ] )
    ]
;;
