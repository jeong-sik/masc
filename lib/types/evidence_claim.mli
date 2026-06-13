(** Evidence_claim — typed deterministic verification evidence (RFC-0199 Phase A).

    Closed sum type for evidence that can be checked without verifier
    judgment: PR merged, CI pass, command exit code, file existence,
    artifact size. Future RFC-0199 Phase B (Deterministic_evidence_evaluator)
    would consume a [t list] and emit a typed CDAL verdict.

    Status (2026-06-03): this schema is currently UNWIRED. The Phase A
    [task_contract.required_evidence_typed] field that was meant to carry
    [t list] was removed (fan-in 0: never populated, never read, no Phase B
    evaluator). The schema is retained for when Phase B is implemented; that
    work must re-introduce a typed field together with a migration from the
    live [task_contract.required_evidence] strings — see RFC-0199.

    Boundary: this module defines the schema only. It does NOT perform
    evaluation, network I/O, or file stat. Evaluation lives in
    [Deterministic_evidence_evaluator] with injected dependencies so
    pure callers (parsers, validators, tests) can manipulate claims
    without side effects.

    Anti-pattern guards (RFC-0088):
    - Closed sum forces exhaustive match in every evaluator.
    - [Custom_check] is the only escape hatch and requires a typed
      [id] from an allowlist + structured [payload]; not a free-form
      string-classifier surface.

    @since RFC-0199 Phase A (2026-05-27) *)

type t =
  | PR_merged of { repo : string; pr_number : int }
  | CI_pass of { repo : string; pr_number : int }
  | Tests_pass of { command : string; expected_exit : int }
  | Artifact_exists of { path : string; min_bytes : int option }
  | File_changed of { path : string; min_bytes : int option }
  | Custom_check of { id : string; payload : Yojson.Safe.t }
[@@deriving show, eq, yojson]

val to_human_string : t -> string
(** Compact one-line summary suitable for transition events and operator
    dashboards. NOT for parsing; use [to_yojson] for round-trip. *)
