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

(** {1 Gate labels for attribution recording}

    Attribution ring-buffer entries are grouped by gate name. Two
    labels are published so advisory vs. strict-enforced verdicts can
    be counted separately in the dashboard. *)

val strict_gate_label : string
(** ["cdal_verdict"]. Used when a rejection actually blocks
    completion. *)

val advisory_gate_label : string
(** ["cdal_verdict_advisory"]. Used when [contract.strict = false]
    and the rejection is dropped — the audit trail is kept but the
    task is allowed through. *)

(** {1 Task completion gate} *)

(** [gate_check ?base_dir ?gate_label ~task_id ()] looks up the latest
    verdict for [task_id] under [base_dir] (default: CDAL verdict
    directory resolved from MASC base path) and returns:

    - [None] — completion is allowed.
    - [Some reason] — completion must be rejected.

    [gate_label] controls the attribution-ring gate name (defaults to
    {!strict_gate_label}). Callers operating on advisory contracts
    should pass [~gate_label:advisory_gate_label] so the dashboard can
    distinguish the two buckets. The return value is unaffected by
    the label. *)
val gate_check :
  ?base_dir:string ->
  ?gate_label:string ->
  task_id:string ->
  unit ->
  string option

(** {1 Attribution wiring} *)

(** [to_attribution ?gate_label v] maps [check_verdict v] to the
    matching {!Attribution.t} — [Allow] → [passed], [Reject reason] →
    [policy_failed]. [gate_label] defaults to {!strict_gate_label}. *)
val to_attribution : ?gate_label:string -> Cdal_types.contract_verdict -> Attribution.t

(** Attribution used when no verdict exists for a task.
    [gate_label] defaults to {!strict_gate_label}. Trailing [unit]
    is required so the optional argument can be erased. *)
val attribution_for_missing_verdict :
  ?gate_label:string -> task_id:string -> unit -> Attribution.t
