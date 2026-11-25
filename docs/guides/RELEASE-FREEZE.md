# Release candidate scope freeze (not a `main` merge freeze)

MASC uses trunk-based development: **`main` stays continuously open for reviewed
merges.** Release preparation freezes a **candidate snapshot** (its version, SHA,
and included range) for complete verification — it never freezes `main`.

## Trunk-based contract: milestone cut, never freeze `main`

- **Never freeze `main` for release prep, RC verification, or publish waiting.**
  Commits landing on `main` after a cut (`ahead_by > 0`) are normal next-version
  work, not release drift. Do not chase `ahead == gap` equality checks, regenerate
  notes to chase moving `main`, or re-freeze `main` while waiting for approval.
- **Control version scope with milestones and cut timing.** When a specific feature
  or fix must ship in `vX.Y.0`, wait to cut until those milestone PRs land on
  `main`. Keep incomplete multi-PR work behind opt-in configuration or feature
  flags so `main` stays shippable.
- **Authoritative release-note scope.** Release notes describe the exact range
  from the previous version tag through the selected candidate SHA (`vPREV...vNEXT`).
  A tag commit does not need to match `main` tip; `scripts/ci/prepare-release-publication.py`
  only requires `behind_by == 0` (the tagged commit is an ancestor of `origin/main`).
- **`MASC_RELEASE_FREEZE` is an operator-explicit emergency brake, not a release step.**
  Keepers and release leaders must not enable `MASC_RELEASE_FREEZE=1` for routine
  release cuts or publication waits. Only an explicit operator incident decision
  may set it (recording incident cause, scope, and lift condition), and it gates
  the automated submissions in `approval-auto-merge` and `approval-merge-sweep`.
  The worker also handles requests recorded by `approval-merge-request`. Manual
  merges remain subject to the repository's usual branch protection rules.

## Freeze the candidate snapshot

The release owner records the version, RC ref (`release/vX.Y.Z-rcN`), initial
candidate SHA, included range, and known blockers in the release ledger/PR.
Select one `main`-ancestor candidate SHA for verification. **Main advancing is
not a reason to change this candidate or halt other PRs.**

The release ledger owns the selected SHA, admitted repairs, run, and result.
Read that record before preparing a repair or assessing evidence; this runbook
does not carry a second current-candidate identity. An initial cut, a
replacement candidate, and a successful verification are separate entries; none
is inferred from the others.

Historical note: during v0.49.0 preparation, the operator once explicitly
stopped `main` inflow (`1123d7bebf45983f6222caeb171896e8469335a6`, RC
[37136996120](https://github.com/jeong-sik/masc/actions/runs/37136996120));
that was a one-off operator decision, not the standing release workflow.

## Repair blockers and roll forward cleanly (`0.x` policy)

A blocker repair must identify a failing candidate scenario, build/type/installation
failure, security defect, or publication defect and explain why it prevents
this version from shipping. Include the exact failing SHA/run or reproduction,
the smallest repair, and its verification target in the PR. A stale fixture may
be corrected only against the intended product contract; preserve its useful
behavior assertions. Do not weaken an assertion, skip a failing suite, or raise
a timeout simply to obtain green CI.

Under the current `0.x` roll-forward policy (matching `check_tag_ancestor`'s
`behind_by == 0` invariant below):
1. Land the reviewed blocker fix on `main` first (trunk-first).
2. Cut a replacement candidate from `main` (creating the new version/changelog
   cut commit on `main` if needed), record old SHA, new SHA, included delta
   (including any already-reviewed commits that landed on `main` in between),
   reason, and old run outcome, and run full RC verification on the new SHA.
3. Do not cherry-pick onto an unmerged side branch to tag directly — tags must
   name a `main` ancestor. Track non-blocking findings for the next version.
   (If a future long-lived maintenance line requires isolated release branches
   with selective `git cherry-pick -x` backports, extend `check_tag_ancestor`
   and this guide deliberately in a dedicated PR.)

## Replace a candidate deliberately

Keep one owner for the release branch. Other agents prepare repair PRs and
report findings; they do not concurrently assemble or push new candidates.
Collect the current run's complete failure inventory, separate product,
fixture and environment failures, then assemble the reviewed blocker repairs.
Do not cancel a useful run just because main advanced. When a concrete blocker
requires a replacement, record old/new SHA, admitted fixes, reason and old run
outcome, then dispatch verification for the new SHA. A manual same-SHA retry is
appropriate for an evidenced infrastructure failure; source changes require
new verification. No retry count or elapsed time can substitute for success.

## Verify behavior as well as compilation

[Release verification scope](RELEASE-VERIFICATION.md) separates mandatory core
flows, changed-surface checks and supporting-tool/extended validation. This is
the target classification, not permission to skip the current candidate's gates.

Compilation checks interface/type correctness. Behavior checks exercise the
shipped feature surfaces, including multi-turn continuity, memory injection,
runtime adapters and user-visible interactions. Keeper-selection and workspace
connection changes require their own concrete affected-surface checks. Keep meaningful
feature tests and installation smoke; source wording, arbitrary snapshots and
checker self-tests are not product behavior proof. Review test cleanup as a
separate change rather than deleting useful coverage during an RC failure.

The current `release-candidate.yml` workflow runs full compile/type checks,
installation checks on the supported platforms, and the explicit essential behavior
selection declared in `config/release-behavior.json` (`release-behavior.yml`).
Full root `@runtest` (`test.yml`) remains a separate manual regression lane.
The candidate ledger records its latest run id, or `미실행` if it did not run
on that candidate. Scoped checks help diagnose repairs but do not replace a complete
successful same-SHA RC. Failed-job reruns for unchanged source may reuse
successful same-run assets under the existing workflow.

## Publish the verified candidate

Require independent review of the final candidate and successful exact-SHA
verification of every declared candidate stage: full type/compile checks,
installation checks on the supported platforms, and the versioned essential behavior profile in
`config/release-behavior.json` (whose exact profile list and SHA-256 hash are
recorded in the candidate receipt). A source approval, partial pass, cancelled
run or old candidate is not complete verification. Production-ready
additionally requires every quantitative gate in
[Production readiness](../PRODUCTION-READINESS-GATES.md). Release tags and published assets identify that verified commit;
publish its existing RC assets with `rc_run_id`, without a fresh rebuild.

Moving `main` does not require recutting the release. A replacement candidate
requires full RC verification at its own SHA before publication.
Published versions/tags/assets are not replaced to repair a release: issue a
patch version. A failed unpublished candidate keeps the same version available.
Public artifact publication and production deployment have separate evidence.

## References

The repository constitution owns development authority; this guide supplies the
release procedure. [Release evidence](../RELEASE-EVIDENCE.md) owns the existing
artifact and publication contract.

Selective backporting follows [GitLab's cherry-pick documentation](https://docs.gitlab.com/topics/git/cherry_pick/).
Published artifact integrity follows [GitHub's immutable release model](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases);
repository immutability settings are not asserted or changed by this document.
Sources checked 2026-10-04 KST; confidence High.

## A release tag must name a main ancestor

Tag only a commit `origin/main` already contains, and make the version bump commit on main (a merged PR), never on a side branch that is not merged back. `scripts/ci/prepare-release-publication.py` refuses a tag whose commit is not an ancestor of `main` (`git merge-base --is-ancestor <tag-target> origin/main` exits 1), because v0.77.0 was tagged on a bump that reached main as a different commit (#54183).
