(** Evidence-quality gates for tool-call benchmark runs.

    These checks validate the benchmark evidence itself before model/tool
    behavior is interpreted. They are intentionally separate from scoring:
    missing route evidence is a harness/data-quality failure, not proof that
    the model chose the wrong tool. *)

val route_evidence_has_semantic_fields : Yojson.Safe.t option -> bool
(** [route_evidence_has_semantic_fields evidence] is [true] when [evidence]
    carries at least one non-empty semantic field (descriptor_id,
    runtime_handler, eval_tags, or receipt_labels) usable for selector
    matching. Empty strings, empty lists, and empty assocs are treated as
    missing, matching {!Eval_tool_selector.matches}. *)

val route_evidence_issues :
     cases:Tool_call_quality_benchmark_types.benchmark_case list
  -> runs:Tool_call_quality_benchmark_types.evidence_run list
  -> Tool_call_quality_benchmark_types.evidence_quality_issue list
(** [route_evidence_issues ~cases ~runs] reports every tool call from a
    scored run whose case uses descriptor/runtime/receipt/eval-tag selectors
    but whose evidence lacks usable [route_evidence].

    Once a case carries at least one semantic selector, {e every} tool call in
    its scored runs must carry usable route evidence: a selector cannot be
    known in advance to target a particular call, and a call without evidence
    cannot be evaluated at all. [route_evidence] is "usable" only when a field
    carries a non-empty value — an empty descriptor/handler string, an empty
    eval-tag list, or an empty receipt-label assoc is treated as missing,
    matching {!Eval_tool_selector.matches}, which yields no match for empty
    values.

    Legacy name-only cases do not require route evidence. Runs that are not
    [Run_ok], unknown cases, and runs for non-declared keeper profiles are
    ignored in the same spirit as {!Tool_call_quality_benchmark_scoring.score_run}. *)
