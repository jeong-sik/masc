# Actual Goal confirmation to one payment

[Run36600485412](https://github.com/jeong-sik/masc/actions/runs/36600485412)
completed successfully at `d0bc9de53aaa62956fb602de8548399b323ab5d5`.
The complete targeted log records all10 `test_candle_goal_flow` cases passing.
Case9 closes the positive orchestration gap without manually appending Candle
facts:

1. Create the shared Goal through its tool; persist a linked Task and a Keeper
   declaration. The Task's Done state is a fixture, not Task-verifier evidence.
2. Call the production proof commit, start the real payout worker and wait for
   its initial scan to finish before calling the HTTP confirmation callback.
3. Require durable Candidates before Grade starts. Hold that injected judgment;
   repeat confirmation and reopen/drop the Goal while no Paid exists.
4. Release Grade. The real worker settles the original obligation while the
   Goal remains Dropped: exactly one Snapshot/PayoutOwed/Candidates/Paid, exact
   confirmed identity,2000 to the contributing Keeper and0 to the caller.
5. Reopen and pass with a distinct verifier run, confirm again, then restart
   and wake the worker. The first identity and balance persist; the settled
   ledger is byte-identical across restart and only three model-edge requests
   occurred in total (Grade, Relation, Weights).

The raw log explicitly records the assertions, worker settlement and all10
case outcomes. It is preserved losslessly in `ci-run-tests.log.gz`; source and
raw hashes are in [provenance.json](provenance.json).

## Limits

Appraiser answers are injected. The production verifier commit is called with
a chosen test verdict; the fixture has no live verifier model installed, as
its warning states. This proves Goal/confirmation/readers/worker/ledger
orchestration and idempotence, not model accuracy, fair grading, a deployed
server or live Keeper behavior. The workspace and broadcasts are isolated
fixture data. Current-main integration after this exact head is tested
separately by run36604111016 and is not inferred from this result.
