---
rfc: "0398"
status: Draft
---

# RFC-0398 — Edit addresses lines and proves freshness; the substring search goes away

- Status: Draft
- Decision driver: the W3 collection (`benchmarks/coding/baselines/20260829-w3`, #31716) measured **7/23 Edit calls missing their `old_string` (30%)**, with episodes recovering only by rewriting whole files through `Write`. A diagnosis-only response was proposed and rejected (#31721) on workaround-bar item 1: it made the miss visible without making it rarer — and its "which line is really the same" judgment was itself approximate matching. The owner's close names the root: the model composes `old_string` without knowing what the file currently holds, so the thing to tighten is the **contract**, not the message.
- Area: `config/tools/Edit.toml` and `lib/keeper/keeper_tool_descriptor.ml` (`translate_edit_file`), `lib/keeper/keeper_tool_filesystem_runtime.ml` (`apply_patch` and the patch dispatch around `:2726`), Read/Write success payloads (same file, `handle_read_file_with_outcome` / write result assembly), `test/test_keeper_fs_edit_patch.ml`.

## Problem (audited)

`Edit {file_path, old_string, new_string, replace_all}` asks the model to
reproduce file bytes from memory and asks the tool to search for them. Both
halves fail in measured ways:

1. The model's reproduction drifts — whitespace shape, or a file that changed
   after the read — and the exact search returns "not found". W3: 30% of
   calls.
2. A miss carries no protocol: the model retries blind, or falls back to
   whole-file `Write` (observed in W3), which discards the read-before-write
   discipline `Edit` exists to encode.
3. Nothing ties the edit to the read that justified it. A file changed by
   another keeper between Read and Edit is silently searched anyway —
   last-write-wins at the byte level (tasks are CAS-guarded; file edits are
   not).

Rejected alternative (#31721): richer miss messages. Explains misses, keeps
their rate, and smuggles an approximate "this line resembles yours" judgment
into a tool that should only state facts.

## Decision

Edit stops searching. One call names **where**, proves **what is there
now**, and states **what it becomes**:

```
Edit {
  file_path       : string   (* unchanged *)
  start_line      : int      (* 1-based, inclusive *)
  end_line        : int      (* 1-based, inclusive; >= start_line *)
  expected_current: string   (* the exact current bytes of lines start..end *)
  new_string      : string   (* replacement for that range *)
  expected_sha256 : string   (* the whole file's sha256, as Read reported it *)
}
```

Application is a pure precondition check, no search anywhere:

- D1 — **address**: `start_line`/`end_line` outside the file is a typed
  refusal naming the file's actual line count.
- D2 — **local proof**: the bytes at the addressed range must equal
  `expected_current` byte-for-byte. On mismatch the refusal quotes the
  range's actual bytes — the tool states what is there, at the address the
  caller named; no judgment about what "resembles" anything.
- D3 — **global proof**: the file's sha256 must equal `expected_sha256`. On
  mismatch the refusal says the file changed since it was read and carries
  the current hash. This is the atomic version check
  `docs/spec/04-turn-lifecycle.md:56-59` already blesses, and it closes the
  multi-keeper silent-clobber gap: two keepers editing one file now conflict
  loudly instead of last-write-wins.
- D4 — **evidence source**: Read and Write success payloads gain a
  `sha256` field so every edit precondition comes from an actual read, not
  from memory. (Write returns the post-write hash so chained edits need no
  re-Read.)
- D5 — **hard cut**: `old_string` / `replace_all` are removed, not
  deprecated. No dual-mode window, no compatibility reader — masc's standing
  rule. The schema stays closed (`additional_properties = false`,
  masc#31573), so a stale-shaped call is refused by name at validation.
- D6 — **replace_all's job**: multi-site edits are multiple addressed calls.
  If collections show that cadence dominating episode budgets, a batched
  `edits[]` on one file is its own decision (RFC-0396 D6-3), unchanged by
  this RFC.

What each failure mode becomes:

| Today | Under this contract |
|---|---|
| whitespace drift → "not found", blind retry | impossible: bytes come from the Read payload, not reproduction |
| file changed since read → silent search of new bytes | D3 typed refusal with the current hash |
| model edits the wrong place confidently | D2 refusal quoting the actual bytes at the named address |
| miss → whole-file `Write` fallback | no miss to fall back from; `Write` keeps meaning "create/replace a file" |

## Line-coordinate ergonomics (consideration, not a decision)

The coordinates come from Read: its payload already carries `offset` and
`returned_lines`, so a model that just read the region holds the range. If
collections show coordinate arithmetic itself failing (off-by-one against
the `content` string), giving Read an explicitly line-numbered rendering is
its own follow-up decision; nothing in this contract presumes it.

## Workaround-gate self-check

- The 30% metric is expected to structurally change, not to be narrated:
  reproduction misses cannot occur when the precondition is the read's own
  bytes. Bar item 1 is answered by construction, not by messaging.
- No string classifier, no approximate matching anywhere — D2 is byte
  equality at an explicit address.
- No compatibility path (bar: hard cut), no new counter, no cap/cooldown.

## Measurement

Same corpus, same command, against `baselines/20260829-w3`
(pass 39.1%, Edit miss 30%):

- expected: the `Edit false` population shifts from search misses to typed
  precondition refusals, and the Write-fallback pattern disappears;
- watched honestly: small local models may fumble line arithmetic at first —
  if pass@1 drops while refusals stay precise, that is a real result about
  this contract for that model class, and the Read-rendering follow-up gets
  its data.

## Boundaries (untouched)

- `Write` semantics, the closed-schema validation chain (masc#31573), the
  approval surfaces (#31640), and the coding-eval harness.
- `apply_patch`'s multi-occurrence arithmetic dies with the search; the
  line-evidence plumbing (`Keeper_file_change_evidence`) stays — the
  addressed range is its natural producer.

## Evidence record

- Evidence: `benchmarks/coding/baselines/20260829-w3/NOTES.md` (7/23 Edit
  misses, Write-fallback episodes); #31721 close rationale (owner);
  `docs/spec/04-turn-lifecycle.md:56-59` (atomic version checks as objective
  invariants); masc#31573 (closed Edit schema).
- Timestamp: 2026-08-29T19:55+09:00
- Confidence: High on mechanism and precedent; Medium on model ergonomics
  under line addressing (explicitly measured, above).
- Delta: replaces the rejected diagnosis direction with a contract under
  which the measured failure class cannot occur; adds the first
  file-level freshness guarantee masc edits have had.
