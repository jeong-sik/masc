# Schedule startup recovery verification

The first focused [Test40355689343](https://github.com/jeong-sik/masc/actions/runs/40355689343)
selected only `test_schedule_consumer_dispatch`, with `minimal=true`, on head
`3fdf8c35554b3d35b6bed57b6ef62495bba09fd8`, ref
`fix/schedule-startup-recovery-20261027`. It completed with **failure**.

The new `seed_unsettled_running` fixture parameter was inferred as
`Schedule_domain.schedule_note` because of the shared `schedule_id` record
label. The suite did not execute. The subsequent correction explicitly types
that parameter as `Schedule_domain.schedule_request`; it does not relax an
assertion or change production recovery behavior.

[test40355689343.json](test40355689343.json) records the workflow identity.
[The selected diagnostic](compile-failure-selected.log) retains the exact
original line numbers from the gh-rendered failed-job log, whose original digest
and selection scope are in [selection.json](selection.json). The full local log
remains under ignored run output. The artifact metadata is a separate Actions
receipt; its archive was not used as the source of this selected diagnostic.

No passing execution, actual server restart, model run, production installation,
or whole-feature result is implied by the source correction.

The original rendered-log digest is a capture-time snapshot, not a promise
that another `gh run view` returns identical rendered bytes. [Review5655713002](https://github.com/jeong-sik/masc/pull/46234#pullrequestreview-5655713002)
reported a 31,097-byte recollection with the same diagnostic. That recollected
raw file is not held in this bundle; the 46-byte difference is calculated from
the reviewer's report, not from an independent byte comparison.
[capture-clarification.json](capture-clarification.json) records the original
58-line boundary: retained lines 52–57 (6), omitted lines 1–51 and 58 (52).
The original capture-time selection manifest is unchanged.
