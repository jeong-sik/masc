# Approval Rules

Keeper approval rules are persisted allow rules owned by
`Keeper_approval_queue_rules`. The canonical data contract is
`Keeper_approval_queue_rules_types`. Loading fails unless every entry satisfies
that contract, so malformed state cannot match a request or authorize a tool
call.

## Persisted Contract

The persisted file is a JSON list. Every entry is an exact object containing:

- `id`: non-blank string
- `keeper_name`: non-blank string
- `tool_name`: non-blank string
- `request_fingerprint`: lowercase SHA-256 string
- `created_at`: finite, non-negative number
- `created_by`: non-blank authenticated actor string
- `source_approval_id`: non-blank originating approval id
- `expires_at`: null or finite Unix timestamp

Missing, duplicate, unknown, or invalid fields reject the whole file. No field
receives a permissive default.

## Rule Expiry

An exact rule with an `expires_at` timestamp stops matching at that timestamp.
`find_matching_rule` returns `Rule_match_expired`, the Gate records the expired
rule id, and the request continues through the configured Gate decision path.
The expired rule remains visible until an operator deletes it. A null
`expires_at` means that the rule does not expire.

## Failure Visibility

Malformed persisted state increments the `keeper_approval_rules`
`invalid_payload` persistence-read-drop metric and makes the rule store
unavailable.
