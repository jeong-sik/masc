(** Cdal_judge -- Phase 1A contract judge with 7 active checks.

    Evaluates a loaded proof bundle against its contract constraints:
    execution mode propagation and escalation, risk class match,
    contract snapshot integrity, required artifact presence,
    review-requirement bridgeability, runtime terminal status
    (completion precondition), and contract tool-denylist containment.

    @since CDAL Phase 1A *)

(** Evaluate all 7 checks and derive run-level verdict. *)
val judge : Cdal_loader.loaded_bundle -> Cdal_types.contract_verdict

(** {2 Individual checks (exposed for testing)} *)

(** Check execution mode propagation and no-upward-escalation. *)
val check_execution_mode : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check risk class matches contract constraint. *)
val check_risk_class : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check proof contract_id matches recomputed hash. *)
val check_contract_snapshot : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check required artifacts are present (always Satisfied post-load). *)
val check_required_artifact : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check review_requirement is either absent or routed to the verification FSM.
    Current OAS v1 evidence is warning-only, so review requirements remain
    [Inconclusive] until explicit verification occurs downstream. *)
val check_review_requirement : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check the proof's terminal [result_status]. Only a [Completed] run can be
    [Satisfied]; [Errored] is [Violated]; [Timed_out]/[Cancelled]/
    [Context_overflow] are [Inconclusive] with a blocking gap (completion
    cannot be verified from an unfinished run). *)
val check_result_status : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check contract tool-denylist containment. First consumer of
    [contract.eval_criteria]: when the criteria is [Keeper_turn_capture_v1],
    a tool in its [tool_denylist] that also appears in the proof's captured
    [capability_snapshot.tools] yields [Violated]; otherwise [Satisfied].
    Other criteria kinds declare no tool denylist and are [Satisfied]. *)
val check_eval_criteria_tool_denylist
  :  Cdal_loader.loaded_bundle
  -> Cdal_types.check_result

(** {2 Exec-outcome verifiable markers}

    Structured evidence lifted out of a completed shell command's
    semantic exit + stdout/stderr, so the verifier cascade can route
    without regex scraping.  Each marker carries a confidence label:
    [`Exact] means the signal was derived from an authoritative
    status (e.g. process exit code), [`Heuristic] means it was
    inferred from the output text and should be cross-checked before
    being treated as proof. *)

type marker_confidence =
  [ `Exact
  | `Heuristic
  ]

type verifiable_marker =
  | Test_pass of
      { count : int
      ; confidence : marker_confidence
      }
  | Test_fail of
      { count : int
      ; confidence : marker_confidence
      }
  | Build_ok of { confidence : marker_confidence }
  | Build_fail of { confidence : marker_confidence }
  | Lint_clean of { confidence : marker_confidence }
  | Lint_dirty of
      { count : int
      ; confidence : marker_confidence
      }
  | Git_clean of { confidence : marker_confidence }
  | Git_dirty of { confidence : marker_confidence }
  | Git_not_a_repo

(** Classify a completed exec outcome.  Returns the empty list when
    no signal can be lifted — callers must treat absence as {i "no
    evidence"}, not as failure.  Markers do not overlap; a single
    command produces zero or one domain-specific marker (tests,
    build, lint, git) though different domains may coexist when the
    output covers several. *)
val of_exec_outcome
  :  semantic:Masc_exec.Exec_semantic.t
  -> stdout:string
  -> stderr:string
  -> verifiable_marker list

(** Stable wire tag, e.g. ["test_pass:2:exact"].  Intended for
    JSON emission and test assertions; not a pretty-printer. *)
val marker_to_string : verifiable_marker -> string
