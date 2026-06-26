# Approval Rules

Keeper approval rules are persisted allow rules. The authoritative path is
`Keeper_approval_queue_rules.rules_path`, which resolves beneath
`Workspace_utils.masc_dir_from_base_path`. They are only loaded when each rule
entry parses as a complete rule. Malformed entries are ignored, reported as
persistence read drops, and cannot match a future request or auto-approve a tool
call.

## Fail-Closed Parse Policy

The persisted file must be a JSON list. Each entry must be an object with these
required fields:

- `id`: non-blank string
- `keeper_name`: non-blank string
- `tool_name`: non-blank string
- `request_fingerprint`: non-blank string
- `max_risk`: one of `low`, `medium`, `high`, or `critical`
- `created_at`: number
- `match_count`: non-negative integer

Optional fields such as `sandbox_profile`, `backend`, `created_by`,
`last_matched_at`, and `source_approval_id` remain optional. A missing
`request_fingerprint_preview` is derived from a valid fingerprint.

No malformed required field receives a permissive default. In particular,
invalid or missing `max_risk` does not default to `high`.

## Rejection Proof

`test/test_keeper_approval_queue_rules.ml` writes a persisted rule whose keeper,
tool, and request fingerprint would otherwise match a low-risk request, but whose
`max_risk` is malformed. The test verifies that:

- `list_rules` skips the malformed rule during load
- `find_matching_rule` returns `None` for the matching request
- the skipped malformed entry increments the `keeper_approval_rules`
  `invalid_payload` persistence-read-drop counter
- rewriting the same persisted shape with a valid `max_risk` loads and matches

This pins the operational behavior: malformed persisted approval rules are not
silently allowed or silently erased.

## Error Variant Boundary

The `InvalidRequest { message; _ }` patterns in keeper runtime/provider error
handling preserve compatibility with the SDK error record shape. They do not
load, parse, match, or serialize approval rules. Approval-rule fail-closed
behavior is owned by `approval_rule_of_yojson`, `list_rules`, and
`find_matching_rule`.
