# Approval Rules

Keeper approval rules are persisted allow rules. The authoritative path is
`Keeper_approval_queue_rules.rules_path`, which resolves beneath
`Workspace_utils.masc_dir_from_base_path`. They are only loaded when every rule
entry parses as a complete rule. A malformed entry fails the whole load, is
reported as a persistence read drop, and cannot match a future request or
auto-approve a tool call.

## Fail-Closed Parse Policy

The persisted file is a JSON list. New writes use one revision envelope per
rule identity:

- `revision`: non-blank mutation revision
- `operation_id`: non-blank ID of the mutation that produced this state
- `presence`: `active` or `deleted`
- `rule`: the complete approval rule

The nested rule requires `id`, `keeper_name`, `tool_name`,
`request_fingerprint` (non-blank strings), and numeric `created_at`.
`created_by`, `source_approval_id`, and `expires_at` may be absent or null.
`expires_at` is an absolute Unix timestamp; a malformed non-null value is
refused rather than becoming a permanent authorization. Unknown or duplicate
fields reject the whole rule store. Malformed state and intent envelopes do
not fall back to permissive defaults.

Deleted rules remain as tombstones with their exact rule and new revision.
They do not list or authorize. An older remembered-approval intent cannot
renew or resurrect a rule after a later renewal or deletion. Replaying the
exact already-applied intent is idempotent; a revision conflict is reported
separately from the explicit one-shot approval.

## Upgrade continuity

The immediately preceding release wrote bare rule objects in this same list.
The file reader accepts only that released shape through the strict rule
parser, marks it active, and derives stable revision and operation IDs from
SHA-256 of the canonical parsed rule. Field order or omitted optional nulls
do not create a different revision. Reading does not rewrite the file. The
next successful rule mutation writes revision envelopes and retains deletion
tombstones. This narrow boundary preserves existing security state; it is not
permission to accept unknown historical or future formats.

Pending snapshots from the preceding release use version11. Their pending
approvals and explicit deliveries remain readable. A delivery without a
captured rule intent is restored as **one-shot only**: its decision, source,
exact request, expiry and grant-consumption state remain, but its old
`remember_rule` flag cannot create or renew a remembered rule. Rules already
written to the old rule file remain available independently. The released
versionless append log uses the same delivery shape only beside its
authoritative v11 snapshot and in that snapshot’s generation. Older
generations were already included in the snapshot and are skipped before
delivery decoding. Current-generation rows beside a v12 snapshot require
the current rule-intent contract; missing intent is a storage refusal, not
a downgrade to one-shot state. New snapshot writes use version12.

No file conversion or runtime-state reset is needed for these released
formats. Unsupported versions and malformed files remain untouched and
unavailable; use a reader that supports their format instead of deleting
unresolved approvals or remembered security state.

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
