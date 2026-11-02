# One immutable selection during runtime construction

PR [#47290](https://github.com/jeong-sik/masc/pull/47290) captures admitted
provider declarations once before credential I/O and derives wire, capabilities,
history replay, thinking policy, context limits, suppression permission and
request pricing from that selection. A removed seed alias cannot regain its
old canonical, base or bare-row policy; an explicitly scoped custom model row
remains available without inventing a provider declaration.

All runs are workflow **Test**, ref `fix/runtime-construction-snapshot-20261101`,
explicit `minimal=true`, existing 600-second targeted-suite guard:

- baseline: [41311278766](https://github.com/jeong-sik/masc/actions/runs/41311278766), checkout `a91a994c630107a767fe77b17fea8df493049ad7`: **FAILURE, 1 PASS / 5 FAIL**.
- intermediate: [41311696892](https://github.com/jeong-sik/masc/actions/runs/41311696892), checkout `2e5d1ffaf36eecfb0cc6f094dddea9585dd91fc8`: **SUCCESS, 153 PASS / 0 FAIL**.
- repaired: [41312230566](https://github.com/jeong-sik/masc/actions/runs/41312230566), checkout `6a98a059ff81ebc3f863b96ff098baac0d7dea0a`: **SUCCESS, 157 PASS / 0 FAIL**.

The same public six-case fixture executes one no-reload control and five
replacement/removal/captured-absence cases. A real private owned regular File
credential suspends construction in Eio. Fork runs its child immediately and
queues the parent first; the parent replaces the private catalog before the
constructor resumes. The pending promise proves that construction has not
returned; it does not prove the worker's physical read is unfinished. The exact
first suspension is established by the inspected current constructor path.
Every baseline failure reaches its policy assertion after the suspension and
credential checks. Fresh selections are constructed before those assertions;
their post-reload policy assertions are reached in the successful candidate.
No sleep, retry, special credential-file type or production test hook is used.

The common six have **one success maintained, five failures fixed, zero
regressions**. They inspect selected policy/price and credential materialization;
they do not send an HTTP request. Intermediate execution is preserved separately
because it predates an independent review's removed-alias P2 and its repair.
The four alias/custom controls run only in the repaired candidate. Other
adapter/Core controls are also candidate-only, not added to the common six.
The repaired total is 157: six common cases and
151 candidate-only controls, including the four new alias/custom cases.
The intermediate total is a separate execution and is never added to that count.

`source-sha256.json` records 33 named inputs and four complete tree IDs at each
actual head. Baseline/repaired root test and config trees are identical; Core
source/test changes are explicit in `source-comparison.json`. Case identities
use source path, group, index and actual fixture SHA, not ellipsized displays.
The common key digest is `5e95a11dd4fcc96b663284dddae9e3e47dadf0d32129094a360c1e6d5f4d76aa`; all repaired
keys hash to `54668465f6d7de29d22ca9d8755433c8eb5558ed97116ae3330bfe4653557282`. Both hash compact
UTF-8 JSON plus one LF. `cases.tsv` gives full names for the common six;
other display names are the retained runner output.

Raw logs stay in ignored campaign artifacts. Retained text is an ANSI/BOM
normalized line-selected derivative preserving every case, checkout, target,
failure assertion and summary. Manifest digests distinguish raw and retained
bytes. No local build or typecheck ran.

Atomic publication of the two global catalog sources and construction-wide
consistency across multiple bindings remain outside this one-binding repair.
Full regression, real provider/account, installed runtime, OS restart and
whole-stack integration are unverified. Source/evidence review is separate
from trusted non-author GitHub approval and merge. #27898 and #27890 remain
open; no issue is closed.
