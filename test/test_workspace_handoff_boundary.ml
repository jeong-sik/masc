(** Tests for {!Workspace_task_transition_executor} handoff ownership
    (RFC-0365).

    A handoff note is authored on the way out and read on the way in. Before
    this change the field was replaced by the caller's argument on every
    action, and entry-class callers never supply one — so claiming a released
    task overwrote the previous owner's note with [None] at exactly the
    boundary the note exists to cross. Verified on the live fleet 2026-08-06:
    release with a summary, claim by a second agent, and backlog.json held
    null.

    The first case is the boundary itself; the rest pin the surrounding
    contract so the fix cannot be satisfied by simply never clearing. *)

module Executor = Workspace_task_transition_executor
module Domain = Masc_domain

let handoff ?(summary = "prior owner note") ?(updated_by = "keeper-a") () :
  Domain.task_handoff_context
  =
  { summary
  ; reason = None
  ; next_step = Some "read the spec before starting"
  ; failure_mode = None
  ; reclaim_policy = None
  ; evidence_refs = [ "note:probe" ]
  ; updated_at = Some "2026-08-06T00:00:00Z"
  ; updated_by = Some updated_by
  }
;;

let task ?handoff_context ~status id : Domain.task =
  { id
  ; title = "probe"
  ; description = "probe"
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-08-06T00:00:00Z"
  ; created_by = Some "operator"
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Domain.no_execution_links
  ; handoff_context
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  ; skills = []
  }
;;

let backlog_of tasks : Domain.backlog =
  { tasks; last_updated = "2026-08-06T00:00:00Z"; version = 1 }
;;

let apply ~action ~new_status ~handoff_context task =
  let update =
    Executor.build_backlog_update
      ~backlog:(backlog_of [ task ])
      ~task_id:task.Domain.id
      ~action
      ~new_status
      ~handoff_context
  in
  match update.Executor.backlog.tasks with
  | [ updated ] -> updated
  | tasks -> Alcotest.failf "expected one task back, got %d" (List.length tasks)
;;

let summary_of (t : Domain.task) =
  Option.map (fun (h : Domain.task_handoff_context) -> h.summary) t.handoff_context
;;

let claimed assignee : Domain.task_status =
  Domain.Claimed { assignee; claimed_at = "2026-08-06T00:00:01Z" }
;;

let in_progress assignee : Domain.task_status =
  Domain.InProgress { assignee; started_at = "2026-08-06T00:00:02Z" }
;;

(* --- 1. The boundary (RFC-0365 §7 test 1) ------------------------------ *)

let claim_preserves_the_previous_owners_note () =
  let released = task ~handoff_context:(handoff ()) ~status:Domain.Todo "task-1" in
  let after_claim =
    apply
      ~action:Domain.Claim
      ~new_status:(claimed "keeper-b")
      ~handoff_context:None
      released
  in
  Alcotest.(check (option string))
    "a second agent's claim keeps the note"
    (Some "prior owner note")
    (summary_of after_claim);
  (* auto-start runs on the same path immediately after a keeper claim, so it
     has to hold too or the note survives for milliseconds. *)
  let after_start =
    apply
      ~action:Domain.Start
      ~new_status:(in_progress "keeper-b")
      ~handoff_context:None
      after_claim
  in
  Alcotest.(check (option string))
    "and the auto-start that follows keeps it"
    (Some "prior owner note")
    (summary_of after_start);
  Alcotest.(check (option string))
    "attribution still points at the author, not the claimant"
    (Some "keeper-a")
    (Option.bind after_start.handoff_context (fun h ->
       h.Domain.updated_by))
;;

(* --- 2. Entry-class does not author (RFC-0365 §7 test 2) --------------- *)

(* The fix must not be "entry-class writes whatever it is handed". An entry
   argument is not a handoff, and honouring it would let a claimant rewrite
   the outgoing owner's account of the work. *)
let claim_ignores_an_argument () =
  let released = task ~handoff_context:(handoff ()) ~status:Domain.Todo "task-1" in
  let after_claim =
    apply
      ~action:Domain.Claim
      ~new_status:(claimed "keeper-b")
      ~handoff_context:(Some (handoff ~summary:"claimant rewrite" ~updated_by:"keeper-b" ()))
      released
  in
  Alcotest.(check (option string))
    "a claim argument does not overwrite the stored note"
    (Some "prior owner note")
    (summary_of after_claim)
;;

(* A task that never carried a note must not acquire one by being claimed. *)
let claim_on_a_noteless_task_stays_empty () =
  let fresh = task ~status:Domain.Todo "task-1" in
  let after_claim =
    apply
      ~action:Domain.Claim
      ~new_status:(claimed "keeper-b")
      ~handoff_context:None
      fresh
  in
  Alcotest.(check (option string))
    "no note in, no note out"
    None
    (summary_of after_claim)
;;

(* --- 3. Exit-class authors (RFC-0365 §7 test 3) ------------------------ *)

let release_replaces_the_note () =
  let held =
    task ~handoff_context:(handoff ()) ~status:(in_progress "keeper-b") "task-1"
  in
  let after_release =
    apply
      ~action:Domain.Release
      ~new_status:Domain.Todo
      ~handoff_context:
        (Some (handoff ~summary:"second owner note" ~updated_by:"keeper-b" ()))
      held
  in
  Alcotest.(check (option string))
    "the closing owner's note replaces the earlier one"
    (Some "second owner note")
    (summary_of after_release);
  Alcotest.(check (option string))
    "and attribution moves with it"
    (Some "keeper-b")
    (Option.bind after_release.handoff_context (fun h -> h.Domain.updated_by))
;;

(* An exit with nothing to say clears the field: the closing owner is the
   authority on its own account of the work, and an absent argument there is a
   statement, not an omission. *)
let release_without_an_argument_clears () =
  let held =
    task ~handoff_context:(handoff ()) ~status:(in_progress "keeper-b") "task-1"
  in
  let after_release =
    apply
      ~action:Domain.Release
      ~new_status:Domain.Todo
      ~handoff_context:None
      held
  in
  Alcotest.(check (option string))
    "an exit with no argument leaves no note"
    None
    (summary_of after_release)
;;

(* --- 4. The model must be able to tell whose note it is ---------------- *)

(* Preserving the note across the boundary is only an improvement if the
   keeper can tell it is someone else's. An unattributed first-person handoff
   reads as the keeper's own recollection, which is worse than showing
   nothing. The refs matter for the same reason: prose that names an artifact
   is useless without the address, and the readers that resolve one are
   already model-visible. *)
let render_carries_attribution_and_refs () =
  let held =
    task
      ~handoff_context:
        ({ summary = "verified the spec already"
           ; reason = None
           ; next_step = Some "post the token"
           ; failure_mode = None
           ; reclaim_policy = None
           ; evidence_refs = [ "artifact:9f3c"; "board:p-c068" ]
           ; updated_at = Some "2026-08-05T13:34:46Z"
         ; updated_by = Some "keeper-a"
         })
      ~status:(in_progress "keeper-b")
      "task-1"
  in
  let rendered = Masc.Keeper_unified_prompt.format_current_task held in
  let contains needle =
    let n = String.length needle and h = String.length rendered in
    let rec scan i = i + n <= h && (String.sub rendered i n = needle || scan (i + 1)) in
    n = 0 || scan 0
  in
  Alcotest.(check bool) "author is stated" true (contains "keeper-a");
  Alcotest.(check bool)
    "and when it was written"
    true
    (contains "2026-08-05T13:34:46Z");
  Alcotest.(check bool) "the summary survives" true (contains "verified the spec already");
  Alcotest.(check bool) "the next step survives" true (contains "post the token");
  Alcotest.(check bool) "artifact ref reaches the model" true (contains "artifact:9f3c");
  Alcotest.(check bool) "board ref reaches the model" true (contains "board:p-c068")
;;

(* A note with no recorded author must say so rather than read as the
   holder's own. *)
let render_marks_an_unattributed_note () =
  let held =
    task
      ~handoff_context:
        ({ summary = "someone left this"
           ; reason = None
           ; next_step = None
           ; failure_mode = None
           ; reclaim_policy = None
           ; evidence_refs = []
           ; updated_at = None
         ; updated_by = None
         })
      ~status:(in_progress "keeper-b")
      "task-1"
  in
  let rendered = Masc.Keeper_unified_prompt.format_current_task held in
  let contains needle =
    let n = String.length needle and h = String.length rendered in
    let rec scan i = i + n <= h && (String.sub rendered i n = needle || scan (i + 1)) in
    n = 0 || scan 0
  in
  Alcotest.(check bool) "absence of an author is stated" true (contains "unattributed")
;;

let () =
  Alcotest.run
    "workspace_handoff_boundary"
    [ ( "ownership boundary"
      , [ Alcotest.test_case
            "claim and auto-start keep the previous owner's note"
            `Quick
            claim_preserves_the_previous_owners_note
        ] )
    ; ( "entry-class does not author"
      , [ Alcotest.test_case
            "a claim argument is ignored"
            `Quick
            claim_ignores_an_argument
        ; Alcotest.test_case
            "a noteless task stays noteless"
            `Quick
            claim_on_a_noteless_task_stays_empty
        ] )
    ; ( "exit-class authors"
      , [ Alcotest.test_case
            "release replaces the note and its attribution"
            `Quick
            release_replaces_the_note
        ; Alcotest.test_case
            "release with no argument clears the note"
            `Quick
            release_without_an_argument_clears
        ] )
    ; ( "the model can tell whose note it is"
      , [ Alcotest.test_case
            "render carries author, time and refs"
            `Quick
            render_carries_attribution_and_refs
        ; Alcotest.test_case
            "an unattributed note says so"
            `Quick
            render_marks_an_unattributed_note
        ] )
    ]
;;
