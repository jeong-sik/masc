# Workspace curator native test and staged candidate

Parent Test 34715042787 completed successfully at
f4fba831a416244c7a868d8ec79283f0ce7a409d: all nine requested suites and 232 cases
passed. The independent audit compares individual case results with each suite's
summary and records the raw log hash. This proves the parent curator commit's
tests, not the later publication/direct-message changes.

Release 34715381302's macOS ARM job 103611571007 succeeded for
a7855af2f7640edffd2c23ae752b6f1e37e610d2. Its artifact was downloaded, and the
packaged installation helper matched that source's helper bytes. The paired
Dashboard/runtime archives and four companions were extracted and verified into
`/tmp/masc-a7855af-installed-candidate-20260913`. Native `build-commit` returned
the expected source. Binary SHA-256 is
93fbec0f483c6763238ee06c4cbb3f32c34070da5d69ea9341ddf31defae10bc;
release manifest SHA-256 is
f126995a24b54ef2f7c41f4eea4e833a8899691d71704efbb6b00b9a26f4dec5.
The staged release directory contains 5,433 files. The prefix transaction was
committed only after the paired verifier and embedded commit/hash checks passed.

This is staged artifact verification. No server was activated from this prefix,
no runtime configuration changed, and the existing 851f412 server was retained.
The discovery/direct-message Test runs were queued when the independent audit
read them; do not infer their success from the parent test or ARM build. Full
Release completion, candidate activation, installed discovery, model execution
and Keeper adoption remain separate acceptance steps.

The source-only prompt contract UI in PR35698 is newer than this artifact and is
not included in it. Its own browser evidence is held in that worktree/PR.
