(** Deterministic_evidence_evaluator — RFC-0199 Phase B.

    Pure evaluator that takes a list of [Evidence_claim.t] (RFC-0199
    Phase A) and an injected dependency record, then returns a typed
    [evaluation_result] consumable by [Cdal_evidence_gate] (RFC-0109).

    Boundary: all side effects (HTTP, exec, fs) are passed in via
    [evaluator_deps]. The evaluator itself is pure — tests inject stubs,
    production wires real implementations. Phase B ships the evaluator
    only; Phase C wires production deps and the transition hook.

    Anti-pattern guards (RFC-0088):
    - Closed-sum [evaluation_result] forces exhaustive match in every
      consumer (warning 4 = error).
    - No counter-only branch: every code path returns a decision, a
      retry signal, or an inconclusive verdict with a structured reason.
    - No string classifier: dep return shapes are typed polymorphic
      variants, not free-form strings.

    @since RFC-0199 Phase B (2026-05-27) *)

type evaluation_result =
  | All_satisfied
  | Partial of
      { satisfied : Evidence_claim.t list
      ; missing : Evidence_claim.t list
      }
    (** At least one claim failed (not transient). [satisfied] +
        [missing] together cover the input claims; order preserved from
        the input. *)
  | Inconclusive of
      { reason : string
      ; transient : bool
      }
    (** Cannot decide right now. [transient = true] = backoff retry
        (CI in progress, network glitch); [transient = false] = block
        the gate (missing repo, malformed claim). *)

(** Result of a single dep call. Closed-sum so consumers cannot
    silently swallow an unrecognised state. *)

type pr_check_result =
  [ `Merged of string  (** ISO8601 mergedAt timestamp *)
  | `Open
  | `Closed_unmerged
  | `Not_found
  ]

type ci_check_result =
  [ `All_pass
  | `Any_fail of string list  (** failing check names *)
  | `In_progress
  | `Not_found
  ]

type exec_result =
  [ `Exit of int
  | `Timeout
  | `Spawn_error of string
  ]

type file_stat_result =
  [ `Exists of int  (** byte size *)
  | `Missing
  ]

type custom_check_result =
  [ `Satisfied
  | `Unsatisfied of string  (** human-readable reason *)
  | `Unknown_id  (** evaluator does not recognise [id] (allowlist miss) *)
  ]

(** Injected dependencies. Production wires real gh / exec / unix
    implementations; tests inject deterministic stubs. *)
type evaluator_deps =
  { gh_pr_check : repo:string -> pr_number:int -> pr_check_result
  ; gh_ci_check : repo:string -> pr_number:int -> ci_check_result
  ; exec_command : command:string -> timeout_sec:int -> exec_result
  ; file_stat : path:string -> file_stat_result
  ; custom_check :
      id:string -> payload:Yojson.Safe.t -> custom_check_result
  }

val evaluate :
  deps:evaluator_deps -> claims:Evidence_claim.t list -> evaluation_result
(** Evaluate all claims and aggregate. Decision rules:

    - Empty [claims] → [All_satisfied] (no requirement = trivially met)
    - All claims satisfied → [All_satisfied]
    - At least one transient inconclusive → [Inconclusive { transient = true; ... }]
      (transient wins over non-transient so callers retry before giving up)
    - At least one non-transient inconclusive → [Inconclusive { transient = false; ... }]
    - Otherwise → [Partial { satisfied; missing }]

    Order: claims are evaluated in input order. Short-circuit only on
    transient inconclusive (cost saving for slow deps); otherwise all
    claims are checked so [Partial.missing] is complete. *)
