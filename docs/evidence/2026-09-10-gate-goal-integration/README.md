# Gate and Goal on one integrated candidate

Candidate `0415aba5b2239db6344ce67e8b66749fde06c8c8` combines Gate tip `0ed0ce8bd2` with main `961f2cc984`. CI run `34417696485`, artifact `10129831962`, supplied the macOS binary. Its SHA-256 is `d32cfcbda061d131784a6b8176b3b8d6cd1b397c45c6793b0eec86af206bd658`. Both harnesses completed with exit code zero. No local build or production replacement occurred.

The Gate fixture used a fresh Docker-shared home base and real approval/replay/artifact paths. The original operation succeeded with its original input digest; the prior Write and approved Execute each occurred once. The 655-byte replay output was read by the actual artifact tool. Four provider requests remained four through shutdown, and the spent wake was explicitly acknowledged without another model turn.

The Goal fixture used a separate isolated server from the same binary. Its synthetic verifier invoked the real file-read tool, then produced a proof bound to the criterion, request, and verification run. Authenticated confirmation recorded the admin identity and exactly one completion event. Unauthenticated access, spoofed identity, stale run, and replay after reopening were rejected as recorded.

These are two independent flows on the same integrated binary, not a Goal-owned Gate task scenario. Providers are synthetic; no semantic LLM acceptance, attachment/channel continuation, restart, or automatic unavailable-authority recovery is claimed. Subsequent main/Fusion changes are not in this candidate.

Integration test run `34417693677` exposed a distinct Goal-list output schema omission despite these successful runtime flows. PR #34985 declares the emitted `awaiting_confirmation_count`; that later repair is not part of this binary. Runtime success must not be read as an all-tests-green claim for 0415.
