(** Keeper_routine_allowlist — code-defined auto-approval rules for keeper
    autonomous task lifecycle.

    Background: in production/enterprise/paranoid governance, certain
    common keeper actions (e.g. masc_transition action=claim, action=done)
    can land on or above the confirmation threshold and stall keepers in
    [awaiting_approval] indefinitely. Operators are not always present to
    approve every routine claim/heartbeat/done.

    This module defines a narrow, code-only allowlist of (tool, action)
    pairs that are safe for autonomous keeper flow. The rules are checked
    by [Governance_pipeline.to_oas_approval_callback] AFTER the existing
    [auto_approval_forbidden] gate, so:

    - destructive_tool_or_op shell or git tools still gate
    - Critical risk still gates
    - runtime_auto_approval_blocked (cascade_exhausted etc.) still gates
    - force_* actions still gate (classified as Critical via "force"
      pattern in {!Governance_pipeline_risk.classify_name})

    The allowlist is intentionally narrow:
    - [masc_transition]: only claim, start, heartbeat, done, release.
      cancel and force_* are NOT allowlisted.
    - [keeper_board_post]: any post at risk Low or Medium.
    - [keeper_task_claim], [keeper_task_done],
      [keeper_task_submit_for_verification]: standard autonomous flow.

    These rules are not persisted; they are part of the policy code surface
    and require code review to change. Operator-managed rules continue to
    flow through {!Keeper_approval_queue.find_matching_rule}.

    @since 2.270.0 *)

(** Returns [true] when the given tool call matches a routine
    allowlist rule. Caller is assumed to be a keeper agent (this is
    only ever invoked from the keeper OAS approval callback path).

    [risk_level] is the risk classification computed by
    {!Governance_pipeline.assess_risk}. [keeper_board_post] is
    rejected at [High]/[Critical].

    Returns [false] for any tool/action pair not on the allowlist;
    this preserves the human-loop for non-routine flows. *)
val matches :
  tool_name:string ->
  input:Yojson.Safe.t ->
  risk_level:Keeper_approval_queue.risk_level ->
  bool

(** A short label describing which rule matched. Returns [None] when
    no rule matches. Useful for audit logs and dashboard observability. *)
val rule_label :
  tool_name:string ->
  input:Yojson.Safe.t ->
  risk_level:Keeper_approval_queue.risk_level ->
  string option

(** Returns the static rule list as JSON for dashboard inspection.
    Shape: [[ { tool, allowed_actions, max_risk, note } ... ]]. *)
val rules_summary : unit -> Yojson.Safe.t
