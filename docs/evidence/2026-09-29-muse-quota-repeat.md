# Muse account quota observed only as modelError

On the server started at `2026-09-29T01:22:20Z` from commit
`60deb5adcc4a7d6a83a8f54c6a83b00336308805`, code-reviewer had repeated
`provider_attempt_effect_fenced` turns. Twelve receipts between 01:23:54Z
and 01:28:14Z contained the same provider `modelError` with HTTP 429 in its
free-text message. The message stated a reset at 2026-10-05T00:00:00Z.
There was no completed answer and no same-turn fallback in these receipts.

MSP's `turn_error` has `kind`, `message`, and `retryable`. It has no typed
HTTP status or quota reset. MASC must not infer an account-wide quota window
from that text. Muse separately exposes `usage/read` without a model turn;
its typed subscription windows carry used percentage and reset time.

After a `Model_error`, this change starts one usage read per selected account
scope on the server root switch. Only a returned exhausted window records a
provider-stated reset in `Runtime_quota_window`. The current turn keeps its
original failure and effect disposition. Failed or absent usage reads record
no quota. The existing route order then rests that account and may select a
different declared path. A later server restart needs a fresh observation;
the quota table is process-local.

The scripted host regressions cover a standalone `usage/read` without a
session or model call, and a failed Keeper turn followed by one independent
usage read. They assert that the original failure, effect fence, recovery row,
and single model turn remain intact; only a typed spent window rests the
selected account, while an unspent or other account remains available.
`git diff --check` and `ocamlformat --check` passed. No local build was run
under the repository execution protocol; CI execution is pending.
