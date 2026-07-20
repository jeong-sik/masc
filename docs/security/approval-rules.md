# Approval Rules

Keeper approval rules are persisted allow rules. The authoritative path is
`Keeper_approval_queue_rules.rules_path`, which resolves beneath
`Workspace_utils.masc_dir_from_base_path`. They are only loaded when every rule
entry parses as a complete rule. A malformed entry fails the whole load, is
reported as a persistence read drop, and cannot match a future request or
auto-approve a tool call.

## Critical Approval Timeout Policy

Production policy for `critical` HITL approvals is fail-closed and
operator-must-decide:

- Critical-risk pending approvals do not expire automatically.
- The keeper turn remains suspended until an operator approves or rejects the
  pending entry. This is intentional because automatic expiry can either deny a
  required recovery action or requeue dangerous work without a human decision.
- Operator coverage is required for unattended autonomous sessions that can
  trigger Critical approvals. At least one operator must monitor the dashboard
  approval queue and audit logs while those sessions are active. If coverage is
  unavailable, pause or stop the keeper instead of relying on a timeout.
- Escalation is manual today: inspect the dashboard approval queue, choose
  approve or reject, or pause/stop the keeper and record the operator action.
  Do not duplicate the decision outside the approval queue.
- Surfacing is split by purpose: the dashboard approval queue is the live SSOT
  for pending decisions, audit approval JSONL records pending/resolved/expired
  events, and keeper logs emit the `HITL_APPROVAL_PENDING`,
  `HITL_APPROVAL_RESOLVED`, and `HITL_APPROVAL_EXPIRED` markers.

Bounded Critical timeout behavior requires runtime work before it can be used
in production: typed timeout/escalation state, cancel/requeue semantics,
dashboard state badges, audit events, and tests for each transition. Until that
work exists, Critical approvals must not auto-cancel, auto-expire, or requeue.

## Fail-Closed Parse Policy

The persisted file must be a JSON list. Each entry must be an object with these
required fields:

- `id`: non-blank string
- `keeper_name`: non-blank string
- `tool_name`: non-blank string
- `request_fingerprint`: non-blank string
- `created_at`: number

`created_by`, `source_approval_id`, and `expires_at` are optional and may be
absent or null. `expires_at` is an absolute Unix timestamp: at and after that
time the rule no longer authorizes. A malformed non-null `expires_at` fails
the entry rather than silently becoming a permanent rule.

No malformed required field receives a permissive default, and any unsupported
or duplicate field rejects the whole file with `explicit re-approval is
required`.

## Rule Expiry

An exact Always Allowed rule with `expires_at` set stops matching at that
timestamp. `find_matching_rule` then reports `Rule_match_expired` instead of
applying the rule; the Gate logs the exclusion and appends a
`gate_exact_rule_expired` audit event carrying the rule id, then falls back to
the configured Gate mode. Expiry never deletes the rule: it stays in the store
and dashboard listing until an operator removes it through the existing delete
path. Rules without `expires_at` never expire, so pre-expiry persisted files
keep their previous behavior.

## Rejection Proof

`test/test_keeper_approval_queue_rules.ml` writes a persisted rule entry with
an unsupported field. The test verifies that:

- `list_rules` rejects the whole rules file
- the rejected entry increments the `keeper_approval_rules`
  `invalid_payload` persistence-read-drop counter

This pins the operational behavior: malformed persisted approval rules are not
silently allowed or silently erased.

## Error Variant Boundary

The `InvalidRequest { message; _ }` patterns in keeper runtime/provider error
handling preserve compatibility with the SDK error record shape. They do not
load, parse, match, or serialize approval rules. Approval-rule fail-closed
behavior is owned by `approval_rule_of_yojson`, `list_rules`, and
`find_matching_rule`.
