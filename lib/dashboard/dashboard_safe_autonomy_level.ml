(** Safe-autonomy domain level + catalog.

    SSOT for the Pass/Warn/Fail status enum, the 5 safe-autonomy
    domain identifiers (tool_correctness, sandbox_truth,
    approval_truth, cascade_fsm_gracefulness, audit_trail_completeness),
    the canonical [domain_catalog] (id, label, weight) tuples used to
    compose the overall safety score, and the level-merge helpers
    [worse_level] / [worst_level].

    Pure data + total functions. No parent-local state, no I/O.
    Extracted verbatim from the head of [Dashboard_safe_autonomy];
    all callers are internal to the parent (verified via grep). *)

type domain_level =
  | Pass
  | Warn
  | Fail

let tool_domain_id = "tool_correctness"
let sandbox_domain_id = "sandbox_truth"
let approval_domain_id = "approval_truth"
let cascade_domain_id = "cascade_fsm_gracefulness"
let audit_domain_id = "audit_trail_completeness"

let domain_catalog =
  [
    (tool_domain_id, "Tool Correctness", 30);
    (sandbox_domain_id, "Sandbox Truth", 20);
    (approval_domain_id, "Approval Truth", 20);
    (cascade_domain_id, "Cascade & FSM Gracefulness", 20);
    (audit_domain_id, "Audit Trail Completeness", 10);
  ]

let level_to_string = function
  | Pass -> "pass"
  | Warn -> "warn"
  | Fail -> "fail"

let level_rank = function
  | Pass -> 0
  | Warn -> 1
  | Fail -> 2

let worse_level left right =
  if level_rank left >= level_rank right then left else right

let worst_level levels =
  match levels with
  | [] -> Warn
  | hd :: tl -> List.fold_left worse_level hd tl
