(** OAS approval callbacks shared across call sites.

    Kept in a standalone module (not in [Governance_pipeline]) so
    callers like [Dashboard_operator_judge] can reference it without
    forming a dependency cycle through [Operator_pending_confirm] and
    the governance approval queue. *)

val auto_approve : Oas.Hooks.approval_callback
(** Always-approve callback for system-level OAS runs that are
    explicitly trusted by MASC: judges, auto_responder, autoresearch
    codegen, deep_review, anti_rationalization, and the OpenAI-compat
    HTTP bridge.

    See the .ml file for the full rationale. TL;DR: keeper runs should
    use [Governance_pipeline.to_oas_approval_callback]; system runs
    that have already decided the caller is trusted should use this. *)
