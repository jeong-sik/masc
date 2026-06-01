(** Diagnostic helpers for "no eligible task" responses in
    [Tool_task.handle_claim_next].

    [no_eligible_diagnostics_json] builds the structured per-bucket
    exclusion counter object that the operator dashboard renders.
    [no_eligible_blocker_summary] formats the blocker summary
    that goes into the human-readable response message body.

    Pure builders — no parent-local state, no I/O. Verbatim extract
    from [Tool_task]; consumed only by the parent's
    [format_no_eligible] (which still lives in the parent because it
    also reads [ctx] and calls [active_goal_phases_for_agent]). *)

let no_eligible_diagnostics_json
      ~excluded_count
      ~blocked_count
      ~verification_blocked_count
      ~scope_excluded_count
      ~explicit_excluded_count
      ~claim_pool_candidate_count
  =
  `Assoc
    [ "excluded_count", `Int excluded_count
    ; "blocked_count", `Int blocked_count
    ; "verification_blocked_count", `Int verification_blocked_count
    ; "scope_excluded_count", `Int scope_excluded_count
    ; "explicit_excluded_count", `Int explicit_excluded_count
    ; "claim_pool_candidate_count", `Int claim_pool_candidate_count
    ]
;;

let no_eligible_blocker_summary
      ~blocked_count
      ~verification_blocked_count
      ~scope_excluded_count
  =
  Printf.sprintf
    "diagnostics: goal_scope_or_filter=%d, verification=%d, blocked=%d."
    scope_excluded_count
    verification_blocked_count
    blocked_count
;;
