# Canonical durable Tool observations — #27890 / #25338

Durable ToolCalled and ToolCompleted previously minted unrelated Event_bus envelopes. This unit projects the existing committed Tool_attempt admission and Tool_result facts through one pure mapper. The source envelope, source sequence and scoped cursor remain unchanged. Blocked/unattempted invocations do not become execution observations. The public cursor reader uses the same immutable validated snapshot for source selection and ancestry; empty filtered pages still advance the source cursor.

A journal-scoped coordinator registers each actual run and its explicit bus, including no bus. Root/recursive shared and distinct buses consume one source-ordered cursor. A successful publication advances only that observation; an ordinary publication failure retains the unacknowledged cursor and does not rewrite committed execution or repeat the Tool handler. Queue acceptance is not subscriber acknowledgement, and retry is at least once. Existing historical audiences are not guessed at resume: explicit durable catch-up belongs to the public reader.

## MASC consumer correction

The initial SDK-only implementation exposed two real product integration failures: reconstructed invocations lost the physical key used by Keeper_execution_join, and a committed Tool_result could reach the bus before the post-hook wrote the product row. Actual run 40211727747 reproduced both through public Agent.run, an actual local Tool handler, the product ID producer and Keeper_event_bridge; the transient control passed.

The correction binds an immutable typed canonical run/node citation before the Gate. Opening a Tool_invocation grants no Tool_attempt or execution permission. Gate, handler and post-hook share the canonical invocation; settlement replay, event projection and the public settled reader reconstruct that same citation. MASC derives its durable product execution ID from the canonical node ID. Only explicit non-journalled invocations use per-live-object association. The citation carries no approval, recovery or replay authority.

ToolCompleted waits until post-effect observers unwind. The hold affects delivery and its source cursor, not the effect or canonical receipt commit. One held result preserves global observation order across concurrent child runs. The coordinator captures publication exceptions inside the mutex, unlocks normally and then rethrows reserved exceptions; dedicated reserved-publication execution coverage has not been added, so that new mutex behavior is source-reviewed only.

## Execution history

| Run | Exact source | Actual result and limits |
| --- | --- | --- |
| [40209856538](https://github.com/jeong-sik/masc/actions/runs/40209856538) | fbc4daddb375ac3b6a93ba64b452e53a6758c88c | Pipeline 72 PASS / 1 FAIL: no canonical sequence on the bus. Later envelope assertions unreached in that baseline. |
| [40210199786](https://github.com/jeong-sik/masc/actions/runs/40210199786) | acbe6a52b40e74d168a3eab270b42ff276b20a78 | Four suites failed before cases: production content match warning 4. |
| [40210525398](https://github.com/jeong-sik/masc/actions/runs/40210525398) | 09dedd57c9b61de7cc6f80ef20ccdaa16795cdfa | 122 PASS = Pipeline74 + projection6 + journal20 + lane22. Predates recursive audience and MASC consumer cases. |
| [40210824598](https://github.com/jeong-sik/masc/actions/runs/40210824598) | ff9a2aa7959b8605fcf43cfda77c1ad16ea1e311 | Pipeline fixture compile failure; no Pipeline cases. Other suites 48 PASS = 6 + 20 + 22. |
| [40211727747](https://github.com/jeong-sik/masc/actions/runs/40211727747) | b481391fd3e9bf48114821385f62c0edaa2d88a0 | Pipeline79 PASS, product bridge 28 PASS / 2 FAIL on completion ordering and product association. |
| [40212409214](https://github.com/jeong-sik/masc/actions/runs/40212409214) | 60b34cc77cba2a25abcb4d29a92b76f008d286f3 | SDK127 PASS = 79 + 6 + 20 + 22. Product fixture did not run: incorrect Masc.Ids module path. |
| [40212994708](https://github.com/jeong-sik/masc/actions/runs/40212994708) | cd54792ad1f3448b42e8e6098465438fba08d952 | **115 PASS = Pipeline79 + projection6 + product bridge30** after fixing the fixture module path and settled-reader identity. Both reproduced MASC failures now pass, along with the transient control and reopened canonical identity assertion. |

The cases use local custom transports, not provider HTTP. Reopening creates a new reader in the same process, not an OS restart. Partial-publication injection accepts an actual bus event and raises before cursor acknowledgement; retry keeps its event identity and the handler executes once. Recursive fixtures cover shared/distinct/absent child buses and concurrent children with explicit barriers. Earlier successes do not prove later assertions or product integration.

Source hashes cover the changed OCaml interfaces, implementations, Dune registration and fixtures. Each bounded excerpt records the complete raw log SHA256 and byte size. Local syntax parsing and whitespace checks are not typechecking or execution. The last complete full regression was not retrieved or run for this unit; selected suites are not a whole regression.

## Review and remaining scope

Two independent source reviewers returned PASS at 373e98fbbd769f67e65a0c829b87194ce3bec638 against parent a2d37a3053b5b0ddb71db52f87e1d014d6bd2d93, full diff SHA256 74178e2d5e03e651f9e1a35ba62586bda3bbe9a6d13c91cb0a238fd775b1b04c. This is source review, not formal GitHub approval. The subsequent source delta only fixes the test module path and adds the changelog. PR #45999 was draft at this review boundary; REST stack is null and native stack submission was unavailable for this repository.

Only durable Tool bus occurrences move in this unit. Agent/turn/provider bus lifecycle facts, Raw_trace export, typed checkpoint commits/recovery and explicit finite-run retention still need the original hard cut. Full canonical dashboard history is also outstanding. No merge, installed runtime, UI, deployment, OS restart or whole-issue completion is claimed. Both issues remain OPEN.

## Final execution boundary

Run 40212994708 completed SUCCESS at exact cd54792ad1f3448b42e8e6098465438fba08d952. All 115 selected cases passed; the product ordering, association and transient controls executed, rather than merely compiling. The previous journal20/lane22 result belongs to 60b34cc77cba2a25abcb4d29a92b76f008d286f3 and is not added to the final 115 or represented as a final-head run. Subsequent source changes are the bridge comment and evidence only; the recorded source hashes make that boundary explicit. Whole #27890 / #25338 acceptance, reserved-publication behavior execution, formal approval, merge and runtime proof remain outstanding.
