(** Cdal_evidence_gate — task/goal completion verification surface.

    The single verification gate for [submit_for_verification] /
    [submit_pr_evidence] / [Done_action when done_redirects_to_verification].

    Task/goal completion is verified by the presence of evidence the
    verifier keeper / human reviewer can inspect downstream — substantive
    notes plus the contract's [required_evidence] entries, or a handoff
    reference (file path, PR number, commit hash, trace id, or any
    reference URL). There is no internal proof/verdict pipeline.

    Decision matrix:

    | task.contract | evidence | Decision |
    |---------------|----------|----------|
    | [None] | any | [Pass] (analysis-only task bypass) |
    | [Some _] | all [required_evidence] mentioned AND (substantive notes OR handoff reference) | [Pass] |
    | [Some _] | otherwise | [Reject] with unsatisfied required-evidence list | *)

(** A decision from the evidence gate. *)
type decision =
  | Pass
  | Reject of
      { reason : string
      ; rule_id : string
      ; hint : string
      ; payload_json : Yojson.Safe.t
      }

val rule_id_evidence_incomplete : string
(** ["cdal_evidence_incomplete"] — a contracted task tried to complete
    without sufficient evidence (required_evidence unsatisfied and no
    substantive notes / handoff reference). *)

(** [decide] applies the evidence-substantiveness matrix above. *)
val decide
  :  task_id:string
  -> task_opt:Masc_domain.task option
  -> notes:string
  -> handoff_context:Masc_domain.task_handoff_context option
  -> unit
  -> decision
