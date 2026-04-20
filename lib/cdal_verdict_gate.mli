(** Cdal_verdict_gate — Deterministic gate that blocks task completion
    when the latest CDAL verdict is [Violated] or [Inconclusive] with
    blocking completeness gaps.

    Reads from [cdal_verdicts/*.jsonl] (produced by
    [Cdal_eval_v1.persist]). Gate logic is pure:
    - [Satisfied] → allow
    - [Violated] → reject with findings summary
    - [Inconclusive] with no blocking gaps → allow
    - [Inconclusive] with blocking gaps → reject with gap summary
    - No verdict available → allow (gate is opt-in per task) *)

(** {1 Types} *)

type gate_result =
  | Allow
  | Reject of string

(** {1 Pure gate logic} *)

(** Translate a verdict to [Allow] / [Reject reason] per the rules
    documented above. Pure — no I/O. *)
val check_verdict : Cdal_types.contract_verdict -> gate_result

(** {1 Task completion gate} *)

(** [gate_check ?base_dir ~task_id ()] looks up the latest verdict
    for [task_id] under [base_dir] (default: CDAL verdict directory
    resolved from MASC base path) and returns:

    - [None] — completion is allowed.
    - [Some reason] — completion must be rejected. *)
val gate_check :
  ?base_dir:string ->
  task_id:string ->
  unit ->
  string option

(** {1 Attribution wiring} *)

(** [to_attribution v] maps [check_verdict v] to the matching
    {!Attribution.t} — [Allow] → [passed], [Reject reason] →
    [policy_failed]. *)
val to_attribution : Cdal_types.contract_verdict -> Attribution.t

(** Attribution used when no verdict exists for a task. *)
val attribution_for_missing_verdict : task_id:string -> Attribution.t
