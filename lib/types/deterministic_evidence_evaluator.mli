(** Deterministic_evidence_evaluator — RFC-0199 Phase B.

    Evaluates a typed {!Evidence_claim.t} (or a list) to decide whether a
    task's declared completion criteria are objectively satisfied, WITHOUT
    verifier judgment. This is the consumer the Phase A schema was missing
    (the reason the [required_evidence_typed] field was fan-in-0 and removed
    2026-06-03); it is introduced together with a producer (the
    [task_contract.evidence_claims] field) and a completion-driving caller.

    Boundary (manifesto: deterministic vs side-effecting): this module is
    pure. All world access — file stat, command execution, forge queries —
    is injected via {!probe}, so parsers, validators, and tests evaluate
    claims without real I/O. Callers in the completion path construct a
    {!probe} backed by the sandbox file system / Shell-IR runner.

    Unknown is never permissive (CLAUDE.md anti-pattern #2): a probe that
    cannot determine an answer returns [None], which the evaluator maps to
    {!Indeterminate}, NOT {!Satisfied}. A task only auto-completes on an
    all-[Satisfied] verdict over a NON-EMPTY claim list. *)

type probe =
  { file_bytes : string -> int option
        (** [Some n] when the path exists with [n] bytes; [None] when absent.
            Absent is a definite answer (Unsatisfied), not Indeterminate. *)
  ; command_exit : string -> int option
        (** [Some exit_code] after running the command; [None] when the
            command could not be run at all (Indeterminate). *)
  ; pr_merged : repo:string -> pr:int -> bool option
        (** [Some true]/[Some false] when the forge state is known; [None]
            when it could not be queried (Indeterminate). *)
  ; ci_passed : repo:string -> pr:int -> bool option
  ; custom_check : id:string -> payload:Yojson.Safe.t -> bool option
        (** Dispatched on the typed [id] (allowlist), not a free-form string
            classifier; [None] for an unknown id (Indeterminate). *)
  }

type outcome =
  | Satisfied
  | Unsatisfied of string  (** a definite "no", with a human reason *)
  | Indeterminate of string  (** could not be evaluated; never auto-completes *)

val eval_claim : probe -> Evidence_claim.t -> outcome
(** Evaluate a single claim. Exhaustive over the closed sum. *)

val eval_all : probe -> Evidence_claim.t list -> outcome
(** [Satisfied] iff the list is non-empty and every claim is [Satisfied].
    An empty list returns [Unsatisfied "no typed claims declared"] — it is
    never vacuously satisfied, so a task without declared claims is never
    auto-completed. Returns the first non-[Satisfied] outcome otherwise
    ([Indeterminate] dominates [Unsatisfied] so a partial probe failure is
    reported as indeterminate rather than a false "no"). *)

val outcome_to_string : outcome -> string
