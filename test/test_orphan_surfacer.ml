(* test/test_orphan_surfacer.ml

   RFC-0294 PR-4: single-owner orphan-task surfacer. Pins the pure grouping the
   orchestrator pulse emits as the [masc_orphan_tasks] gauge:
   - Every status class in [orphan_status_classes] is reported (0 when empty), so
     a cleared class resets the gauge instead of going stale.
   - An AwaitingVerification orphan is counted under "awaiting_verification" — the
     class [cleanup_zombies] Phase 3 never releases (RFC-0220 §5), which R1g made
     invisible at the keeper wake-driver. T6.
   - Drift guard: the fixed class labels equal [task_status_to_string] of the
     orphan-eligible statuses, so a rename of the canonical strings fails here
     rather than silently splitting the metric vocabulary. *)

module WQ = Masc.Workspace
module MD = Masc_domain

let make_task ~id ~status : MD.task =
  { id
  ; title = "Test Task"
  ; description = ""
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2024-01-01T00:00:00Z"
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }

let count_of cls counts =
  match List.assoc_opt cls counts with Some n -> n | None -> -1

(* T6: an AwaitingVerification orphan is surfaced under its own class, and the
   other classes report 0 (fixed-set emission, no stale value). *)
let test_emits_for_awaiting_verification () =
  let awaiting =
    make_task ~id:"t-av"
      ~status:
        (MD.AwaitingVerification
           { assignee = "dead-keeper"
           ; submitted_at = "2024-01-01T00:00:00Z"
           ; verification_id = "v-1"
           ; phase = MD.Awaiting_verifier
           })
  in
  let counts = WQ.orphan_counts_by_status_class [ (awaiting, "dead-keeper") ] in
  Alcotest.(check int) "awaiting_verification orphan counted" 1
    (count_of "awaiting_verification" counts);
  Alcotest.(check int) "claimed class reports 0 (not absent)" 0
    (count_of "claimed" counts);
  Alcotest.(check int) "in_progress class reports 0 (not absent)" 0
    (count_of "in_progress" counts)

(* Mixed input: counts are per-class and the result always covers every class. *)
let test_counts_per_class () =
  let claimed1 =
    make_task ~id:"c1"
      ~status:(MD.Claimed { assignee = "a"; claimed_at = "2024-01-01T00:00:00Z" })
  in
  let claimed2 =
    make_task ~id:"c2"
      ~status:(MD.Claimed { assignee = "b"; claimed_at = "2024-01-01T00:00:00Z" })
  in
  let inprog =
    make_task ~id:"i1"
      ~status:(MD.InProgress { assignee = "c"; started_at = "2024-01-01T00:00:00Z" })
  in
  let counts =
    WQ.orphan_counts_by_status_class
      [ (claimed1, "a"); (claimed2, "b"); (inprog, "c") ]
  in
  Alcotest.(check int) "two claimed orphans" 2 (count_of "claimed" counts);
  Alcotest.(check int) "one in_progress orphan" 1
    (count_of "in_progress" counts);
  Alcotest.(check int) "no awaiting_verification" 0
    (count_of "awaiting_verification" counts);
  Alcotest.(check int) "every class present in result"
    (List.length WQ.orphan_status_classes) (List.length counts)

(* Empty audit -> every class reports 0 (the gauge resets, never goes stale). *)
let test_empty_is_all_zero () =
  let counts = WQ.orphan_counts_by_status_class [] in
  List.iter
    (fun cls ->
      Alcotest.(check int)
        (Printf.sprintf "%s is 0 on empty audit" cls)
        0 (count_of cls counts))
    WQ.orphan_status_classes

(* Drift guard: the fixed labels mirror task_status_to_string of the
   orphan-eligible statuses. A rename of the canonical strings fails here. *)
let test_class_labels_match_task_status_to_string () =
  let label status = MD.task_status_to_string status in
  let expected =
    [ label (MD.Claimed { assignee = "x"; claimed_at = "t" })
    ; label (MD.InProgress { assignee = "x"; started_at = "t" })
    ; label
        (MD.AwaitingVerification
           { assignee = "x"
           ; submitted_at = "t"
           ; verification_id = "v"
           ; phase = MD.Awaiting_verifier
           })
    ]
  in
  Alcotest.(check (list string))
    "orphan_status_classes mirror task_status_to_string (drift guard)"
    expected WQ.orphan_status_classes

(* The typed classifier is the membership SSOT: every orphan-eligible status maps
   to its Some-label, every non-orphan status maps to None, and the Some-range
   equals orphan_status_classes. A new task_status constructor is a compile error
   in orphan_status_class_of_status (it cannot reach here as a silent drop); this
   test additionally pins that the Some-range and the reported class set agree, so
   adding a class without listing it (or vice versa) fails. *)
let test_classifier_is_membership_ssot () =
  let some label = Some label in
  Alcotest.(check (option string)) "claimed -> Some claimed"
    (some "claimed")
    (WQ.orphan_status_class_of_status (MD.Claimed { assignee = "x"; claimed_at = "t" }));
  Alcotest.(check (option string)) "in_progress -> Some in_progress"
    (some "in_progress")
    (WQ.orphan_status_class_of_status (MD.InProgress { assignee = "x"; started_at = "t" }));
  Alcotest.(check (option string)) "awaiting -> Some awaiting_verification"
    (some "awaiting_verification")
    (WQ.orphan_status_class_of_status
       (MD.AwaitingVerification
          { assignee = "x"; submitted_at = "t"; verification_id = "v"; phase = MD.Awaiting_verifier }));
  Alcotest.(check (option string)) "todo -> None" None
    (WQ.orphan_status_class_of_status MD.Todo);
  Alcotest.(check (option string)) "done -> None" None
    (WQ.orphan_status_class_of_status (MD.Done { assignee = "x"; completed_at = "t"; notes = None }));
  Alcotest.(check (option string)) "cancelled -> None" None
    (WQ.orphan_status_class_of_status (MD.Cancelled { cancelled_at = "t"; cancelled_by = "x"; reason = None }));
  (* Some-range over every constructor equals the reported class set. *)
  let some_range =
    List.filter_map WQ.orphan_status_class_of_status
      [ MD.Todo
      ; MD.Claimed { assignee = "x"; claimed_at = "t" }
      ; MD.InProgress { assignee = "x"; started_at = "t" }
      ; MD.AwaitingVerification
          { assignee = "x"; submitted_at = "t"; verification_id = "v"; phase = MD.Awaiting_verifier }
      ; MD.Done { assignee = "x"; completed_at = "t"; notes = None }
      ; MD.Cancelled { cancelled_at = "t"; cancelled_by = "x"; reason = None }
      ]
  in
  Alcotest.(check (list string))
    "classifier Some-range == orphan_status_classes"
    WQ.orphan_status_classes some_range

let () =
  Alcotest.run "orphan_surfacer"
    [ ( "orphan_counts_by_status_class"
      , [ Alcotest.test_case "emits for awaiting_verification (T6)" `Quick
            test_emits_for_awaiting_verification
        ; Alcotest.test_case "counts per class" `Quick test_counts_per_class
        ; Alcotest.test_case "empty audit is all-zero" `Quick
            test_empty_is_all_zero
        ; Alcotest.test_case "class labels match task_status_to_string" `Quick
            test_class_labels_match_task_status_to_string
        ; Alcotest.test_case "typed classifier is membership SSOT" `Quick
            test_classifier_is_membership_ssot
        ] )
    ]
