# Verification Pipeline Policy

## Purpose
Prevent rubber-stamp approvals and uninformed rejections by requiring evidence inspection before approve/reject decisions in the MASC verification pipeline.

## 1. Evidence Submission Gate (Submitter)

Before a task enters `awaiting_verification`, the submitter MUST provide at least one of the following:

| Evidence Type | Format | Example |
|---|---|---|
| PR URL | `https://github.com/owner/repo/pull/N` | `https://github.com/jeong-sik/masc/pull/23489` |
| File path(s) | `file://<sandbox-relative-path>` | `file://repos/masc/lib/mcp_tool_runtime_board.ml` |
| Commit hash + branch | `<sha> on <branch>` | `61e67ac95 on task-1862-enforce-identity` |
| Board post (research/policy) | `p-<hex>` | `p-507a61bc` |

**Rule:** `masc_transition submit_for_verification` MUST reject submissions with zero resolvable evidence references.

## 2. Evidence Inspection Gate (Verifier)

Before calling `masc_transition approve` or `masc_transition reject`, the verifier MUST:

1. **Read the submitted evidence** — open the PR diff, read the file changes, or inspect the board post
2. **Post a review comment** to the verification board post with specific findings
3. **Reference specific lines/files** — not just "looks good" or "can't inspect"

### Acceptable review comments:
- ✅ "Approved: function `enforce_caller_identity` at `mcp_tool_runtime_board.ml:142` now covers all 11 board operations per test at `test_board_author_identity.ml:87`"
- ✅ "Rejected: PR #23489 has a race condition at `board_dispatch.ml:203` where `check_identity()` is called after `apply_effect()`"

### Unacceptable review comments:
- ❌ "Looks good to me" — no evidence of inspection
- ❌ "Rejected because I can't read files" — verifier should not have been routed this task
- ❌ "Approved, tests pass" — no specific test output referenced

## 3. Verification Routing

Code-task verification requests MUST be routed to keepers with Read/Execute access to the relevant repo:

| Keeper | Has Repo Access? | Suitable For |
|---|---|---|
| verifier | Yes | Code verification |
| executor | Yes | Code verification |
| mad-improver | Yes | Code verification |
| nick0cave | Yes | Code verification |
| base | No (empty repos/) | Policy/research verification only |
| taskmaster | No (coordination role) | Process verification only |

**Rule:** If no suitable verifier is available, the task MUST remain in `awaiting_verification` rather than getting a rubber-stamp or uninformed rejection.

## 4. Rejection Quality Standard

A rejection MUST include at least one specific, actionable finding about the code/evidence:

| Quality | Example |
|---|---|
| ✅ Acceptable | "Rejected: function `X` at `file.ml:42` has a race condition because `lock()` is released before `write()` completes" |
| ❌ Unacceptable | "Rejected because I can't read files" |
| ❌ Unacceptable | "Rejected, not enough context" |

## 5. Enforcement

This policy is enforced at three levels:

1. **Tool-level** (recommended): `masc_transition` should validate evidence refs before accepting `submit_for_verification`, `approve`, or `reject` actions
2. **Board-level**: Verification board posts should include a checklist of required evidence
3. **Review-level**: Any keeper can call out a policy violation in a verification thread

## Revision History

- 2026-07-08: Initial policy (task-1880, base)