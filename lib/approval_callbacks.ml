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
