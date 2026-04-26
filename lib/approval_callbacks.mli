(** OAS approval callbacks shared across call sites.

    Kept in a standalone module (not in [Governance_pipeline]) so
    callers like [Dashboard_operator_judge] can reference it without
    forming a dependency cycle through [Operator_pending_confirm] and
    the governance approval queue. *)

(** Always-approve callback for system-level OAS runs that are
    explicitly trusted by MASC: judges, auto_responder, autoresearch
    codegen, deep_review, anti_rationalization, and the OpenAI-compat
    HTTP bridge.

    See the .ml file for the full rationale. TL;DR: keeper runs should
    use [Governance_pipeline.to_oas_approval_callback]; system runs
    that have already decided the caller is trusted should use this. *)
val auto_approve : Oas.Hooks.approval_callback

(** Fail-closed default callback for OAS Agent builder sites that do
    not have an explicit human-in-the-loop or MASC-trusted-system
    decision source. Returns [Reject _] on every ApprovalRequired
    tool call with a structured reason naming the tool.

    Closes the fail-open gap described in #7883: previously, Agent
    builder sites with [approval = None] logged "ApprovalRequired
    but no approval callback — executing" and executed the tool
    anyway. Install this (or an explicit callback) at every builder
    site to make the decision explicit. *)
val reject_by_default : Oas.Hooks.approval_callback
