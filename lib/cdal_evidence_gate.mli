(** Cdal_evidence_gate — explicit task verification evidence surface.

    The evidence gate for [submit_for_verification].
    Normal [Done_action] completion is LLM-reviewed by
    {!Anti_rationalization}; it is not redirected through a verifier keeper.

    Explicit verification submission is checked for the presence of evidence
    the reviewer can inspect downstream — substantive
    notes plus the contract's [required_evidence] entries mentioned as
    standalone reference tokens, or a trusted handoff reference (PR number,
    commit hash, trace id, or reviewer-inspectable URL). File-shaped refs are
    only shape-recognized until an artifact/base-path validation layer can prove
    they exist inside the allowed workspace. Blank required evidence entries are
    treated as unsatisfied. There is no internal proof/verdict pipeline.

    Classification matrix:

    | task.contract | evidence | Decision |
    |---------------|----------|----------|
    | [None] | trusted handoff_context.evidence_refs | [Pass] |
    | [None] | missing/empty/untrusted handoff_context.evidence_refs | [Reject] |
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

(** [classify_evidence] applies the evidence-substantiveness matrix above
    without consulting the rollout enforcement switch.  This keeps the
    evidence classifier auditable while enforcement is disabled. *)
val classify_evidence
  :  task_id:string
  -> task_opt:Masc_domain.task option
  -> notes:string
  -> handoff_context:Masc_domain.task_handoff_context option
  -> unit
  -> decision

(** [decide] preserves evidence classification for diagnostics but currently
    returns [Pass] for every task because the CDAL evidence gate enforcement is
    disabled by operator directive. *)
val decide
  :  task_id:string
  -> task_opt:Masc_domain.task option
  -> notes:string
  -> handoff_context:Masc_domain.task_handoff_context option
  -> unit
  -> decision
