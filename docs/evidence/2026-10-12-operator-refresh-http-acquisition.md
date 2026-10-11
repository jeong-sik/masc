# Operator refresh ownership cancels HTTP acquisition

Parent: `b5f005441471b69362425ef95a906714236beebb` (#42440).

Two real API/refresh-path fixtures reproduced previous-owner snapshot/digest HTTP requests remaining un-aborted after credential replacement (`/tmp/operator-refresh-http-red-20261012.log`). They import real core, refresh effects and credential state; only fetch and SSE registration are mocked. The fetch fixture observes the actual AbortSignal and rejects on its abort event. Failure cleanup supplies a response and awaits the request, preventing abandoned work.

Actual refresh reads now subscribe an AbortController to credential replacement and pass its signal through the snapshot/digest API options into core GET acquisition. Authentication replacement aborts the actual fetch signal. Nested final cleanup releases the auth subscription even when a loading observer throws. Inflight/queued operation ownership and previous-account publication guards remain intact. Queued work creates its own controller only when it becomes a read.

Focused checks completed: `npx vitest run src/operator-refresh-http-ownership.test.ts src/operator-actions.test.ts` passed two suites / 51 tests (`/tmp/operator-refresh-http-focused-20261012.log`), and `npx tsc --noEmit` exited 0. The changed digest-call fixture requires the signal as part of its actual API admission contract.

This proves cancellation while awaiting response headers. Core GET currently detaches its upstream listener when headers arrive, so response-body lifetime still requires separate repair and evidence. Already-visible account projections, pending/log partition and downstream UI also remain outstanding. No live server/provider, screenshot, installation, CI or formal approval is claimed. The full chat goal remains active.
