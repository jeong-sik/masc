(** #10421: pre-fix the [task_claim_next_auto_release] JSONL event
    carried only [agent] and [released_task] — operators could not
    discriminate which prior status the release was reverting from
    (43 claimed→todo vs 1 in_progress→todo on 2026-04-25, very
    different signals).  This test pins [task_status_label] which
    feeds the new [from_status] field and the existing [to_status]
    column dashboards already index by. *)

open Alcotest
module C = Masc_mcp.Coord
module T = Masc_domain

let check_label expected status =
  check string ("label of " ^ expected) expected
    (C.task_status_label status)

let now_iso = "2026-04-26T00:00:00Z"

let claimed = T.Claimed { assignee = "k1"; claimed_at = now_iso }
let in_progress =
  T.InProgress { assignee = "k1"; started_at = now_iso }
let awaiting =
  T.AwaitingVerification {
    assignee = "k1";
    submitted_at = now_iso;
    verification_id = "req-1";
    deadline = None;
  }
let done_ = T.Done {
  assignee = "k1";
  completed_at = now_iso;
  notes = None;
}
let cancelled = T.Cancelled {
  cancelled_at = now_iso;
  cancelled_by = "operator";
  reason = Some "test";
}

let test_all_variants () =
  check_label "todo" T.Todo;
  check_label "claimed" claimed;
  check_label "in_progress" in_progress;
  check_label "awaiting_verification" awaiting;
  check_label "done" done_;
  check_label "cancelled" cancelled

let () =
  run "task_status_label_10421" [
    ("status_label", [
        test_case "every variant maps to canonical lowercase label"
          `Quick test_all_variants;
      ]);
  ]
