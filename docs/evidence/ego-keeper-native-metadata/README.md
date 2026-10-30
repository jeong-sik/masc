# Isolated Keeper to native Ego metadata

A real `glm-coding.glm-5.3-flash` Keeper completed one
`BrowserAct(action=space_status)` through the candidate Browser Add-on and
installed Ego SDK. Its canonical tool result identifies the original client,
Space 32, `agentDelegatedToUser`, and the SDK observation time. The matching chat
run ended with `RUN_FINISHED`. A retained host observation also records
`keeper/ego-metadata-proof`, `space_status`, and `returned`.

This proves that this metadata request and caller publication worked. It does
not prove that the browser window or Dashboard was visible, or that login worked.
The recorded activity is a last result, with no pending interactions; it is not
proof of currently running work.

## Exact execution scope

- Candidate source: `d840b7978ce01ca0afdb1f4fcdedce0d4596e991`.
- Workflow: **Minimal manual checks**, run
  [40389493765](https://github.com/jeong-sik/masc/actions/runs/40389493765),
  workflow head `55ed503a3363b4621289cb25d2c7cbda345066b2`, ref
  `ci/ego-space-proof-20261026`, conclusion **success**. The 12 ordered targeted
  invocations and their arguments/exit codes, plus four executable hashes, were
  verified. This is not full regression.
- A separate loopback server used an isolated base path and those verified
  binaries. The shared installation was not replaced. Health binds the running server hash
  to the artifact; its Dashboard asset surface reports `missing` with no index,
  so this candidate provides no rendered Dashboard evidence.
- The Keeper declared `microvm/apple_container` with the already installed
  `masc-sandbox:general` image promoted in the isolated workspace. This host
  browser tool has no sandbox execution; no guest execution or image build is
  claimed.
- The later Dashboard control-publication head `e8b93756082d86ace00c23418607423692e7b7e7`
  was **not** executed by this probe.

[receipt.json](receipt.json) contains the sanitized canonical tool result,
matching main-chat terminal, dated host caller publication, binary identities and
explicit limits. Raw provider prompts/reasoning, credentials and login output
are excluded. The original private audit files are hash-bound where referenced.

## Controller failure remains a failure

The controller forwarded original real-provider SSE only after parsing its tool
calls. It permitted tool discovery and one exact-client `space_status`, and
blocked other tool proposals. The metadata call and main chat completed, but an
additional response proposed multiple tools and was refused. The controller
summary therefore remains **failed**.

Its concurrent request-index allocation was not protected, so the exact request
that produced the additional refused response is unproven. A finished main chat
does not turn this controller into a passing end-to-end harness. Earlier attempts
also failed: the first workspace had no promoted Docker image; the initial proxy
did not support SSE. Those failures remain in the private audit trail and are
summarized in the receipt.

[controller-attempt-03.py.txt](controller-attempt-03.py.txt) preserves the exact
executed controller bytes and their hash. It is a frozen investigation artifact,
with its original paths and known indexing defect, rather than a reusable test
runner. The generic earlier controller filename did not identify this execution.

## Browser ownership boundary

“Once” refers to the canonical Keeper `BrowserAct(space_status)` call. Worker
attachment and separate before/after direct `listTaskSpaces` metadata reads also
occurred. No claim of one total SDK invocation is made.

Before and after the isolated server stopped, native inventory showed the same
Space 32 and `agentDelegatedToUser`. These are two dated observations, not
continuous control monitoring. This delegated-state probe does not prove real
SDK teardown of an active agent-owned Space or cleanup of uploaded files. No
Page/input/navigation/claim/takeover/finish was part of the authorized Keeper
request. Window visibility, login, input reset, full SDK/Goal support, formal CR
clearance and whole-stack merge remain unverified.
