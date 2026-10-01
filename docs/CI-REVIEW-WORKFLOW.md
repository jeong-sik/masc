# Review first, manual CI

The operator's 2026-09-30 policy is authoritative in `docs/constitution.xml`.

Work proceeds in stacked PRs. The bottom PR targets main; each later PR targets the preceding branch. Review function, logic and code cleanliness from independent perspectives. Approve the current head when no P0, P1 or P2 issue remains. Record P3 items for a later cleanup. Ordinary reviews do not need a CI run ID. Land stacks bottom first and review base/head changes before landing.

Native GitHub Stacks use REST `stack` metadata and the [stack workflow](guides/NATIVE-GITHUB-STACKS.md). The asynchronous merge endpoint includes all open downstack PRs through the selected PR. Inspect and approve every included head; do not treat a non-main direct base as a blocker or manually retarget a native stack. A leaf source-review PASS does not certify its downstack.

There is no PR, general push or scheduled CI. Issue taxonomy reconciliation remains operational automation. `pr-check.yml` runs explicit source/config syntax and credential checks. `ci.yml` runs only the Core library for the bottom of a stack. Neither links or runs the whole test graph. These workflows are requested deliberately; agents do not dispatch them on every push or watch/poll for completion. Prefer short, focused checks: the constitution's "about two minutes" describes their intended scale, not a timeout or a pass/fail threshold. A cold toolchain/dependency cache can take longer. Only an actual successful completion is build evidence.

At a `release/vX.Y.Z` branch, explicitly run `release-candidate.yml`. It invokes all full-check jobs, the complete Test workflow and installation/package verification on the same head. Tag publication in `release.yml` also waits for full checks and behavior tests. `full-check.yml` is reusable only; it has no autonomous trigger. Specialized host/proof workflows remain available by explicit dispatch.

The scripts under `scripts/review/` use source review for ordinary stacks and completed full CI for release heads. The ordinary verdict is `verdict: PASS head: <40-hex SHA> by: <reviewer>`. Release verdicts additionally cite `run: <full CI run ID>`. Reviews remain current-head bound and may not approve their own changes; latest blocking reviews and FAIL/HOLD decisions take precedence. GitHub main protection has no required ordinary CI contexts. Branch integrity remains protected; source review admission is checked by the review scripts.

CI must catch a concrete functional, compilation, schema, credential or resource-boundary failure. Byte inventories, prose wording, cosmetic source spelling, historical counts and recursive checks about other checks are not release evidence. Feature work continues while explicit verification is running; CI improvements follow their own stack.

Release verification runs full builds, type checks, functional suites, model checks, credentials, and distribution/installation behavior. Bulk source-style lints, documentation wording rules, and exception-exemption count budgets are not release gates. Review P3 findings are collected separately.
