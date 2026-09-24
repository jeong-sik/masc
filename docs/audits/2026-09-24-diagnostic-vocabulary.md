# Diagnostic vocabulary audit — 2026-09-24

This is the first inspected slice of message, variant, error, and log wording.
It is not a repository-wide completion claim. The criterion is whether two
fields or phrases carry the same fact, rather than whether they share a word.

## Confirmed overlap and repair

| Surface | Same fact before | Change |
| --- | --- | --- |
| Librarian exact preflight (`keeper_librarian_runtime`) | `Exact_request_projection_failed.slot_id` repeated the first ID already embedded in its formatted `reason` list. A single-slot failure printed the ID twice. | Keep each slot ID beside its typed `Exact_output.admission_error` until rendering. The error line prints every refused slot once in declared order. |
| Librarian CLI fallback (`keeper_librarian_runtime`) | `API failure:` wrapped an error that already identified the API projection; the WARN said `cli lane-slot failed` before `failure_to_string` said the same thing. | Compose the API and CLI details without a second failure label; use `librarian fallback:` for the WARN. |
| TUI exact-run detail (`masc_tui_render`) | `RUN failed` was followed by `FAILURE librarian_failed`. | Label the second line `CODE`, preserving the machine code and detail without a second status word. |

## Similar names that carry different facts

- `Keeper_skill_activation_projection` and `Keeper_snapshot_unread` emit a
  short `reason` code plus a separate diagnostic `detail`. These are distinct
  wire fields and were left intact.
- `Runtime_verification.unmeasured` carries `code`, a human `message`, and an
  optional producer `detail`. Its decoder checks that only codes with details
  receive one; collapsing these would discard a contract distinction.
- `Keeper_runtime_attempt` maps provider `detail` into the HTTP client's
  `message` field at a type boundary. The source value is transferred, not
  stored twice in one error.

## Remaining audit areas

- Other exact-output lanes' preflight and fallback errors.
- Runtime/provider error conversion and the final operator log wrapper.
- Dashboard and TUI renderers that print a status next to a code with the same
  status word.
- Wire records with both code/reason and detail/message: check the producer
  and decoder before changing any schema.
