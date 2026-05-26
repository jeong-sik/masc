(** Cdal_evidence_gate — RFC-0109 Phase D.

    Layered evidence-gate decision for [submit_for_verification] /
    [submit_pr_evidence] / [Done_action when done_redirects_to_verification].

    Replaces the substring-classifier-only gate in
    [Tool_task_completion_review.verification_submission_evidence_error]
    (§2.3 workaround signature #2 per RFC-0001) with a typed CDAL
    verdict consultation, falling back to the legacy substring shim
    only when no verdict is available and the task carries a contract.

    Decision matrix (see RFC-0109 §6.5.2):

    | CDAL verdict | task.contract | Decision |
    |--------------|---------------|----------|
    | [Some Satisfied] | any | [Pass] |
    | [Some Violated] | any | [Reject] with typed findings |
    | [Some Inconclusive] | any | [Pass] if [required_evidence] satisfied; else [Reject] with completeness_gaps + required list |
    | [None] | [None] | [Pass] (analysis-only task bypass) |
    | [None] | [Some _] | fall through to legacy substring shim |

    @since RFC-0109 Phase D (2026-05-26) *)

(** A decision from the evidence gate. *)
type decision =
  | Pass
  | Reject of
      { reason : string
      ; rule_id : string
      ; hint : string
      ; payload_json : Yojson.Safe.t
      }

(** Rule identifiers exposed for testing and for the workflow_rejection
    payload [rule_id] field. *)

val rule_id_violated : string
(** ["cdal_verdict_violated"] *)

val rule_id_inconclusive : string
(** ["cdal_verdict_inconclusive_incomplete"] *)

val rule_id_substring_fallback : string
(** ["submit_verification_missing_evidence"] — preserved verbatim from
    the legacy gate so operators / log queries / dashboards keyed on
    this rule_id keep working. *)

(** Build the typed JSON payload describing a [Violated] verdict's
    rejection. Embedded in [workflow_rejection_payload_json] so the
    operator sees [findings[]] with check_id / observed / expected /
    trace_ref instead of an opaque "include pr_url..." hint. *)
val payload_of_violated_verdict
  :  task_id:string
  -> Cdal_types.contract_verdict
  -> Yojson.Safe.t

(** Build the typed JSON payload for an [Inconclusive] verdict whose
    completeness_gaps or unsatisfied [required_evidence] entries block
    the gate. *)
val payload_of_inconclusive_verdict
  :  task_id:string
  -> required_evidence:string list
  -> Cdal_types.contract_verdict
  -> Yojson.Safe.t

(** [decide] applies the §6.5.2 matrix.

    [lookup] defaults to
    [Cdal_verdict_gate.lookup_latest_verdict ~warn_on_missing:false ?base_dir].
    Tests inject a stub so they do not require the dated_jsonl store. *)
val decide
  :  ?lookup:(task_id:string -> Cdal_types.contract_verdict option)
  -> task_id:string
  -> task_opt:Masc_domain.task option
  -> notes:string
  -> handoff_context:Masc_domain.task_handoff_context option
  -> unit
  -> decision
