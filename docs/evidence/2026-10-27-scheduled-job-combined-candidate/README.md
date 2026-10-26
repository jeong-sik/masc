# Selected scheduled Job combined-source candidate

[Selection](selection.json) binds base main
`9377c7f3025d68e3856d2afd3762468dabc77813` and assembled product head
`66b0d26af22ed635a159a768fd937f36f0c4cc1d`. The MASC leader explicitly selected
#46234 → #46233 → #46240 → #46248, then #46202, for a single runtime candidate.
#46253's new evidence layer and #46206's disposable CI definition are excluded.
The selected original commits are replayed with `git cherry-pick -x`; this is
existing source assembled for verification, not a reimplementation.

A separate clone preserves the operating checkout and all original stacks.
Draft PR #46263 was created through `gh stack init` and `gh stack submit`.
Its current REST `stack` is null; #46263 is the PR number, not a native-stack
number. This draft is a proof candidate; do not merge it
into main as another copy of those product PRs. No installed binary, primary
server or original PR source has been changed by this assembly.

Each of the five source slices has the same canonical full raw Git diff identity
as its original GitHub PR change. Those identities include complete before/after
blob IDs, modes and paths as used by `scripts/review/review-diff.py`. Patch IDs
also match. No conflict resolution or product-source edits were needed.
This proves source selection, not compatible runtime behavior or a new approval.
The documentation in this layer is added after the recorded assembled product head.
Any later build must record its own exact source input and workflow execution head.

The initial verifier compared #46202's direct base-to-head difference and flagged
a mismatch. The actual PR uses the three-dot merge base
`fae95aaf9575fff4c9c7a18cd1dcf1d428d4227a`, distinct from its base-ref snapshot
`a7e0feac83eed783f87e054f0f5bebec22330560`. Correcting the comparison to that
GitHub-reported merge base made both identities match. The candidate was not
modified to remove a check or undo unrelated main changes. Original failed and
corrected verifier captures remain separately under ignored
`artifacts/schedule-combined-candidate-20261027/`.

[Leader selection excerpt](leader-selection-excerpt.json) is explicitly a derivative
and preserves the leader's limitation: their selection checked approvals and
file overlap, not full integration logic or approve-guard footers. Original
per-PR approvals, previous 117/420/161 test results and older model probes do
not establish this combined head's build, runtime, visible TUI, installation,
restart or external-effect correctness. Those results remain unexecuted here.
