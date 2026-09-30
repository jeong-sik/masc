# Quiz answers remain bound to their captured deck

The original grader joined by fact ID and a declared deck incarnation. Rotating
a deck's bytes while keeping that incarnation could make a wrong choice for an
older question count as correct against the replacement answer. It also allowed
a fact from another source with the same ID to answer that question.

The grader now requires matching source ID, incarnation, fact ID, immutable
snapshot URI/SHA-256 and cited record. Missing immutable question evidence
refuses observation. A mismatched capture refuses the answer before adding any
grade or score; refreshing both observations to the same capture succeeds.

`stdio-tests.log` retains the actual package-worker stdio result: 26 tests pass,
including same-incarnation rotation with refusal and recovery, another source's
fact substitution, missing snapshot digest, existing namespace/claimed-label
checks and bounded large-question replies. `original-grader-negative-control.log`
retains all three new scenarios failing against the original grader from the
base commit recorded in `provenance.json`. Sources, commands and hashes are
recorded there. The host-shaped inputs retain the original two-source interface.

These are Python worker measurements with synthetic retained source fixtures.
No Docker image, native host, Keeper, live installation or CI build was exercised.
The 0.1.2 grader image must be prepared before changing an installed manifest;
manifest publication and reconciliation are separate from these local results.
