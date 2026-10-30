# Typed canonical checkpoints — #27890

## Resulting contract

An Agent executing with a journal and no caller checkpoint sink now freezes its candidate checkpoint through the strict existing codec, commits a typed root update and exposes the latest root checkpoint with its source event/cursor. The frozen fact contains immutable validated JSON; each restoration decodes a fresh Context. The reducer accepts the fact only on the matching Agent root while it is open. Child checkpoints remain under their own runs and cannot replace the root result. The public facade exports Checkpoint_snapshot and the existing checkpoint stage enum aliases that single definition.

Checkpoint ownership is exclusive. An explicit caller checkpoint_sink still owns persistence and its required errors/exceptions still reject continuation. That path does not also append a canonical checkpoint. With neither sink nor journal, state remains in memory. The public reader returns absence explicitly; it does not fall back to another store. This is a prerequisite for the complete checkpoint hard cut, not completion of it.

## Authority finding and corrected scope

The initial implementation incorrectly treated every checkpoint_sink as an optional observer and suppressed ordinary failures after journal commit. Independent review found actual MASC callers still validate scope, publish input ownership and advance Native/Owner state inside this callback. Swallowing those refusals would permit unauthorized continuation. The response review confirmed this finding, and the activation was removed before acceptance. These callers must migrate through a typed authority boundary before their writer can be removed; automatic canonical checkpoint recovery and input/caller-rejection transitions outside an active execution scope remain unfinished.

The initial two regression assertions also had the wrong oracle: they expected required caller refusal to become success. Their 79 PASS / 2 FAIL baseline is recorded as an exploratory rejected premise, not a reproduced product defect. Revised required-sink tests now require refusal, one settled Tool effect, no subsequent provider call and no second checkpoint writer. A separate baseline on source52154457dd3691b9d4e3c24194f5a447c2fd7dd4 checks the actual no-sink gap through the pre-existing public root event stream, without importing the new API.

## Execution boundaries

- 40214920697 /235acf0876be9d4f1f9cedd56ecf8b87e2f51a79: zero cases; missing Alcotest qualifier in the initial exploratory fixture.
- 40214984887 /06a6de822f390761afea9ccba7ca8b6242f332da: actual81,79PASS/2FAIL; the two refusals were correct existing authority behavior, so this is not bug-fix evidence.
- 40215354533 /3e3d1c923b20559c096cbb83a77df4c0c12ba6fb: zero cases in the selected valid suites; missing public facade and fatal non-exhaustive journal test. Advanced target was also misspelled and ran no cases.
- 40215507460 /82c8fc0d86cace0c6f4bed12e378040359e2d6e0: actual131,130PASS/1FAIL. Projection fixture used invocation turn1 under turn0. This candidate still had the unsafe sink suppression and no success from it certifies the corrected contract.
- 40215791578 /15b9700c21b3a6d2b9af87bd986d04cb30109b7f: actual122PASS=Pipeline81+Journal20+Advanced21. Projection ran zero cases due a test Context alias collision. This source has the corrected exclusive authority boundary.
- 40215877213 /52154457dd3691b9d4e3c24194f5a447c2fd7dd4: **actual79,77PASS/2FAIL**: both ordinary and partial-delivery fixtures have no root checkpoint updates. This is the valid missing-fact baseline; later envelope assertions in those failed cases were unreached.
- 40216063083 /240358b788505f4073eaea21ce5cb59e797c267e: **actual9PASS**, only Projection selected after fixing the Context qualifier and turn ordinal. All producer freezing, strict codec, identity, child exclusion, closed-root and reopen assertions executed. Production and the other selected fixtures are byte-identical to15b, verified by a diff whose only path is test_execution_projection.ml. The prior122 exclude Projection and are not a final-head aggregate.

The new public fixtures check actual Agent execution, frozen checkpoint presence without a caller sink, exact citation, fresh-reader replay and independent Context copies. The projection fixture checks strict malformed/duplicate/unknown-field rejection, producer mutation isolation, Agent/root ownership, child exclusion and closed-root refusal. A stale caller checkpoint recovery fixture now uses a reserved interruption rather than inventing an ordinary-sink crash; it still checks durable Tool settlement replay when current tools are removed or changed.

These use local injected transports and fresh same-process readers. They do not prove OS restart, real provider HTTP, installed runtime/UI, full regression, formal approval, merge, automatic canonical recovery, migration of Owner/input/caller-rejection writers, remaining bus/Raw_trace projections, retention or whole-issue completion. No local Dune build/typecheck was run. Parsing and whitespace checks are not execution proof.

Two independent source reviewers returned PASS at240358b788505f4073eaea21ce5cb59e797c267e/base8cb4004602fddc68bcb13a27ef3f7e8dd363d229/diff8014f3b337ec193a193b4a26860adf2cb6cb01f319bf1f81d78f64372e6dd8df after the authority/facade/exhaustiveness and fixture corrections. These are source reviews, not GitHub approval or compiled-test evidence. PR #46003 is draft/open/unmerged; local gh stack adoption succeeded, native submission reports repository disabled and REST stack:null. Original #27890 remains OPEN.

## Final source and execution assessment

The corrected no-sink baseline proves absence of any root update using the prior public schema; current Pipeline fixtures additionally assert the exact typed checkpoint, source identity/cursor and fresh Context. Projection-only 40216063083 completed SUCCESS at exact240358b788505f4073eaea21ce5cb59e797c267e with9PASS. This is separate from122PASS in40215791578 at15b9700c21b3a6d2b9af87bd986d04cb30109b7f. Verified source identity carries those three suites through the Projection-fixture-only correction; no single final-head131-case run is claimed. Seven complete raw-log digests/byte sizes and21 source/fixture hashes are retained. Full regression and final hard-cut completion remain unproved.
