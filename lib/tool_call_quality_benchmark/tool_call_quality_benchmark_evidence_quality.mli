(** Evidence-quality gates for tool-call benchmark runs.

    These checks validate the benchmark evidence itself before model/tool
    behavior is interpreted. They are intentionally separate from scoring:
    missing route evidence is a harness/data-quality failure, not proof that
    the model chose the wrong tool. *)

val route_evidence_issues :
     cases:Tool_call_quality_benchmark_types.benchmark_case list
  -> runs:Tool_call_quality_benchmark_types.evidence_run list
  -> Tool_call_quality_benchmark_types.evidence_quality_issue list
(** [route_evidence_issues ~cases ~runs] reports every tool call from a
    scored run whose case uses descriptor/runtime/receipt/eval-tag selectors
    but whose evidence lacks usable [route_evidence].

    Legacy name-only cases do not require route evidence. Runs that are not
    [Run_ok], unknown cases, and runs for non-declared keeper profiles are
    ignored in the same spirit as {!Tool_call_quality_benchmark_scoring.score_run}. *)
