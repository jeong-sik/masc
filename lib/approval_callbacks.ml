(** OAS approval callbacks shared across call sites.

    Kept in a standalone module (not in [Governance_pipeline]) so callers
    like [Dashboard_operator_judge] or [Tool_deep_review] can reference
    it without forming a dependency cycle through
    [Operator_pending_confirm] and the governance approval queue. *)

(** Always-approve callback for system-level OAS runs that are
    explicitly trusted by MASC: judges (operator/governance),
    auto_responder, autoresearch codegen, deep_review,
    anti_rationalization, and the /v1/chat/completions OpenAI-compat
    bridge.

    OAS emits [WARN] "ApprovalRequired but no approval callback —
    executing" when a run has [approval=None] and a tool is flagged as
    ApprovalRequired. For keeper runs the correct callback is
    [Governance_pipeline.to_oas_approval_callback] (HITL queue +
    trifecta risk). For system runs there is no human on the other
    side, so the correct semantics is "always Approve" — passing this
    callback makes the trust decision explicit at the call site and
    silences the stray WARN line. *)
let auto_approve : Oas.Hooks.approval_callback =
  fun ~tool_name:_ ~input:_ -> Oas.Hooks.Approve

(** Fail-closed default callback for OAS Agent builder sites that do
    not have an explicit human-in-the-loop or MASC-trusted-system
    decision source.

    Every OAS [Agent.t] constructed by MASC must install an
    approval_callback. Without one, OAS logs [WARN] "ApprovalRequired
    but no approval callback — executing" and executes the tool
    anyway (fail-open). [oas_log_bridge] promotes that WARN to ERROR
    for visibility, but promotion is not a gate — the tool still
    runs. See #7883.

    Use this callback at the Builder / run_named site when neither
    [Governance_pipeline.to_oas_approval_callback] (keepers with HITL
    queue) nor [auto_approve] (explicitly trusted system runs) is
    wired. It rejects every ApprovalRequired tool call with a
    structured reason so the caller fails loudly rather than
    executing silently.

    Callers wanting auto-approval must opt in explicitly by passing
    [auto_approve]. This changes the default from fail-open to
    fail-closed. *)
let reject_by_default : Oas.Hooks.approval_callback =
  fun ~tool_name ~input:_ ->
    Oas.Hooks.Reject
      (Printf.sprintf
         "MASC approval fail-closed: tool %s requires approval but no \
          approval_callback was wired at this Agent builder site. \
          Install Governance_pipeline.to_oas_approval_callback (keeper \
          HITL) or Approval_callbacks.auto_approve (trusted system run) \
          at the construction site. See #7883."
         tool_name)
