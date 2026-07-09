(** RFC-0323 G-5 readiness gate 3 audit — unit tests for the pure core.

    [audit_tasks_without_actionable_verification_ids] is the inverse of the
    wake join: it lists AwaitingVerification tasks whose verification_id has no
    actionable verification-store record. Such orphans never wake (the join
    requires the record) and starve silently under the G-5 default-on flip. *)

open Alcotest

module Inputs = Masc.Keeper_world_observation_inputs
module D = Masc_domain

let mk_awaiting ~id ~vid : D.task =
  { D.id
  ; title = "t"
  ; description = ""
  ; task_status =
      D.AwaitingVerification
        { assignee = "alice"
        ; submitted_at = "2026-07-09T00:00:00Z"
        ; verification_id = vid
        ; phase = D.Awaiting_verifier
        }
  ; priority = 1
  ; files = []
  ; created_at = "2026-07-09T00:00:00Z"
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }
;;

let test_audit_lists_only_orphans () =
  let with_record = mk_awaiting ~id:"t1" ~vid:"v1" in
  let orphan = mk_awaiting ~id:"t2" ~vid:"v2" in
  let todo = { with_record with D.id = "t3"; D.task_status = D.Todo } in
  let orphans =
    Inputs.audit_tasks_without_actionable_verification_ids
      [ "v1" ]
      [ with_record; orphan; todo ]
  in
  check (list (pair string string)) "orphans only" [ "t2", "v2" ] orphans
;;

let test_audit_empty_when_all_have_records () =
  let t1 = mk_awaiting ~id:"t1" ~vid:"v1" in
  let t2 = mk_awaiting ~id:"t2" ~vid:"v2" in
  let orphans =
    Inputs.audit_tasks_without_actionable_verification_ids [ "v1"; "v2" ] [ t1; t2 ]
  in
  check (list (pair string string)) "no orphans" [] orphans
;;

let () =
  run "keeper verification audit (RFC-0323 G-5 gate 3)"
    [ "audit"
      , [ "lists awaiting tasks without an actionable store record", `Quick
          , test_audit_lists_only_orphans
        ; "empty when every awaiting task has a record", `Quick
          , test_audit_empty_when_all_have_records
        ]
    ]
;;
