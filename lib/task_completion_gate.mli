(** Task_completion_gate — deterministic L1 evidence gate for task completion.

    A task may complete (Done / Submit_for_verification) only when the caller
    supplies at least one trusted, reviewer-inspectable evidence reference on
    [handoff_context.evidence_refs]. Trust is not inferred from string shape:
    the ref must resolve under [base_path] to an existing artifact file, a local
    git commit, or a local .masc trace/turn/receipt artifact. This is the
    RFC-0311 Phase 1 "universal default" bar — one flexible requirement across
    code and non-code tasks.

    What the gate deliberately does NOT accept as proof:
    - Completion [notes]. Free-text notes are not inspectable and were the
      substring surface that previously let both over-blocking (unknown keepers
      rejected) and fake-done (labels pasted to pass) through the same line.
    - URLs and PR numbers. They are shape-recognized by {!Evidence_ref}, but
      this deterministic gate does not perform network/forge validation, so they
      fail closed until a verifier resolver proves them.
    - File-shaped references ([file://] URIs / relative paths) that do not
      resolve to an existing file inside [base_path].

    The contract's [required_evidence] entries are NOT consulted for this
    decision (they still feed the anti-rationalization reviewer prompt and
    verifier records). Binding completion to specific evidence KINDS — e.g. a
    code task requires a PR — is RFC-0311 Phase 2.

    Decision matrix:

    | task_opt | trusted handoff_context.evidence_refs | Decision |
    |----------|---------------------------------------|----------|
    | [Some _] | present (>= 1)                         | [Pass]   |
    | [Some _] | absent / untrusted / file-shaped only  | [Reject] |
    | [None]   | (missing live task)                    | [Reject] (fail closed) | *)

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
(** ["cdal_evidence_incomplete"] — a completion was attempted without a trusted
    [handoff_context.evidence_refs] reference. Retained verbatim across the
    RFC-0311 rewrite: asserted by downstream tests and consumed offline by the
    completion-trust audit. *)

val decide
  :  base_path:string
  -> task_id:string
  -> task_opt:Masc_domain.task option
  -> notes:string
  -> handoff_context:Masc_domain.task_handoff_context option
  -> unit
  -> decision
(** [decide] applies the L1 evidence matrix above. [notes] is used only for
    diagnostic logging and the reject payload summary, never for the pass/fail
    decision. *)
