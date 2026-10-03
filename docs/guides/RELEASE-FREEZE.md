# Release freeze and candidate repair

Release preparation has a finite scope. Freeze a version's source and included
changes before its full RC; keep developing the next version on main.

## Freeze

The release owner records the version, release branch, initial frozen SHA,
included changes and known blockers in the release PR. Select one candidate
SHA for verification. Main advancing is not a reason to change this candidate.
Do not merge or rebase main, bulk-update dependencies, add features, refactor
unrelated code, or import unrelated test cleanup into a frozen release.

For the current v0.49.0 preparation, the operator has explicitly stopped main
inflow. Candidate `1123d7bebf45983f6222caeb171896e8469335a6` and RC
[37136996120](https://github.com/jeong-sik/masc/actions/runs/37136996120) identify
the selected scope, not a successful verification result. This policy change
belongs to its own main-targeted PR; it does not extend that candidate.

## Admit only release blockers

A repair must identify a failing candidate scenario, build/type/installation
failure, security defect, or publication defect and explain why it prevents
this version from shipping. Include the exact failing SHA/run or reproduction,
the smallest repair and its verification target in the PR. A stale fixture may
be corrected only against the intended product contract; preserve its useful
behavior assertions. Do not weaken an assertion, skip a failing suite, or raise
a timeout simply to obtain green CI.

Develop the repair from the release branch or selectively backport a reviewed
fix with `git cherry-pick -x <commit>`. Review prerequisites individually; a
dependency on new main features is not permission to merge main wholesale.
Track unrelated findings as issues for the next version. Carry release-only
fixes forward to main separately so they are not lost after publication.

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

The current full RC runs the root `@runtest` once, plus full compile and four
platform installation checks. Scoped checks help diagnose repairs but do not
replace that complete successful same-SHA RC. Failed-job reruns for unchanged
source may reuse successful same-run assets under the existing workflow.
Changing this verification architecture is a separate next-version change.

## Publish the verified candidate

Require independent review of the final candidate and successful exact-SHA full
RC. A source approval, partial pass, cancelled run or old candidate is not full
verification. Release tags and published assets identify that verified commit;
publish its existing RC assets with `rc_run_id`, without a fresh rebuild.

Integration back into main is a separate obligation. Moving main does not
require recutting the release. If a required merge creates or rebases to a new
commit that will be tagged, that commit becomes the candidate and requires full
verification; do not substitute old-head evidence or weaken merge safeguards.
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
