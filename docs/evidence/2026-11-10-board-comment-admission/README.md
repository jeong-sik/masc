# Board comment admission candidate — Draft with a known P2

This capture describes production source `0b00cbce749dd2967f1837238133c3f40df72ddf`
and fixture source `2c7fc482f4cd95a12732ceaf2cdc349fdfcacc94`, based on
`fde2dc31e49c7d8e10b017e8e860be5fe2a94819`. Later changelog/evidence commits
must not turn these pins into typing, execution or completion proof.

The boundary reader reaches canonical parent validation and the durable append.
Author remains the independent input to sub-board posting policy. The read-set
holds Posts -> Policy (whenever a hearth exists) -> Comments. An unregistered
hearth remains valid, with the observed policy absence guarded. Unscoped parents
do not require policy availability. Worker callbacks use captured filesystem
inputs; caller-side classification preserves actual append known/unknown
results and inner-to-outer guard cleanup.

## Confirmed blocker

A successful public `delete_sub_board` currently saves policy removal but only
marks the post hearth unlink dirty in memory. Cached hearth=None then differs
from canonical Some slug. The new admission check refuses the immediate normal
comment until a later flush. One independent source reviewer found this P2,
and it remains unresolved. Neither dirty flags nor removing the comparison
constitute proof of the intended owned durable unlink.

The ninth new case requires accepted sub-board deletion, an immediate comment,
and a fresh store with the unlinked hearth and retained comment. It is expected
to fail by source analysis in this candidate, but has never been executed.
The next prerequisite is durable, restart-safe ownership of that unlink,
including interrupted/unknown writes and foreign-row preservation. Root #26378
already tracks that fundamental work and stays open.

## Evidence boundary

[Validation](validation.json) retains the 40 lower parse commands and hashes;
all 40 bytes match at the upper capture. Three upper sources were parsed
separately. Compiler was 5.5.1; repository target is 5.5.2. No type or warning
check ran. Nine new admission cases plus the retained 16 deletion/recovery and
five generic guard cases give 30 backend cases, all unexecuted.

The earlier recovery bundles retain their original bytes and capture pins.
The copied deletion fixture changes only three calls to pass the required
trusted-local Operator reader. The generic guard fixture is unchanged.

Initial upper source `3dc7df6` used a nonexistent IO close field and an append
hook that did not execute. Independent source review caught both. The corrected
fixture uses the actual close_fd API, a seeded existing comments data FD for
real exec contention, and the Posts stable-lock inode for cleanup injection.
Both readers reread the final fixture and found no additional fixture P0-P2.
The production hearth P2 still prevents Ready/approval of this candidate.

No Dune/build, backend test execution, HTTP/browser integration, CI,
installation or deployment was performed. These records support source review
and syntax only. They do not prove the candidate works or close the root issue.
