---
rfc: "0126"
title: "Silent fallback discipline (typed split for option/result wildcard arms)"
status: Implemented
created: 2026-05-17
updated: 2026-08-08
author: vincent
supersedes: []
superseded_by: null
related: ["0106", "0127"]
implementation_prs: [15959, 16000, 16019, 16024, 16189]
---

# RFC-0126 — Silent fallback discipline

## Contract

A boundary must not collapse distinct states into a permissive default.

- Missing, invalid, unavailable, and explicitly empty inputs are distinct typed
  outcomes.
- An unknown enum or protocol value is an error, not a known constructor.
- A failed read does not become an authoritative empty snapshot.
- A failed write does not become success because a log or counter was emitted.
- A best-effort observer may absorb an ordinary exception only when its caller
  contract explicitly permits that loss.
- `Eio.Cancel.Cancelled` always follows RFC-0106 and propagates as control
  flow.

Use a closed variant or `Result.t` at the boundary. Apply a default only after
the typed outcome proves the state is genuinely absent and the contract names a
default for that absence.

## Examples

```ocaml
type load_result =
  | Missing
  | Loaded of value
  | Invalid of parse_error
  | Unavailable of io_error
```

A consumer may choose a value for `Missing`; it must handle `Invalid` and
`Unavailable` explicitly.

For closed vocabularies:

```ocaml
match status_of_string input with
| Some status -> Ok status
| None -> Error (Unknown_status input)
```

Do not map `None` to a semantically unrelated constructor.

## Enforcement

`scripts/lint/no-unknown-permissive-default.sh` guards the narrow lexical
shape where an unknown literal falls through to a known constructor. It is a
ratchet, not a semantic proof. Focused tests must exercise each typed outcome
through its real caller.

Review must trace producer, parser or store adapter, consumer, and caller. A
counter or warning is evidence only; it does not repair the control flow.

## Review checklist

- Does the type distinguish every state the caller treats differently?
- Can malformed or unreadable input reach the same branch as absence?
- Can an unknown value silently select a valid mode?
- Can an exception become success, an empty list, or `None` without an
  explicit best-effort contract?
- Does cancellation still propagate?
- Does the focused test observe the public boundary rather than a duplicate
  helper or string list?
