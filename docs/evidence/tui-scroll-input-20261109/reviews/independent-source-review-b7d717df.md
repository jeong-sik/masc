Independent source review: C overrun input drain

Head `b7d717df36de2aa91b62b413df3cad67739c499d`; base `d4ae1ead0b2bc2a3763858dcde672bdcc4d3ecea`. Frozen source only. No product edits, builds, test execution, CI queries or external posts. `git diff --check`: PASS.

Verdict: no unresolved runtime/API/test P0/P1/P2 finding in this delta.

Continuous pending Input uses the previous completed work timestamp plus the existing interval. Background still uses the start timestamp. Drained Input and Force remain immediate (`render_schedule.ml:35-63`). Pending Input/Force still returns zero input timeout, so coalescing does not add a blocking reader wait (`68-79`).

Every Render decision clears old completion before recording its new start (`45-50`). The image/MSX and pre-Build deferred branches do not record completion and therefore use that new start fallback (`masc_tui.ml:42671-42690`). The only production completion call follows the synchronous normal Build and `time_present` return (`42789-42799`). `time_present` invokes its callback directly and returns after it (`frame_timing.ml:649-676`); the only production take belongs to the same serial loop, so a previous completion cannot arrive after a newer frame has started.

`completed` does not mutate pending requests or priority (`render_schedule.ml:27-33,65-66`), including Input requested while presenting a preset confirmation (`masc_tui.ml:30233-30240`). The new mli signature agrees with the implementation. The three added tests inspect scheduler decisions, pending survival, Force/Background priority and deferred start fallback (`test_tui_render_schedule.ml:119-159`). Their execution was not performed in this review.

Documentation boundary: the extra `changelog.d/50502.md` preserves B documentation according to the parent. C has no PR yet; its own numbered fragment remains pending PR creation. This is not reported as a runtime defect.

No measured performance improvement is claimed. Compilation, focused tests and burst/mixed PTY behavior remain separate evidence. Future asynchronous/reentrant callers would need a distinct completion-order contract; no such caller is present here.

Frozen file SHA-256:

- `bin/masc_tui.ml`: `446e0bf8472b73d67df50798ab08f7c45224caac1a329dc76b33dbeae4fe9903`
- `bin/masc_tui_render_schedule.ml`: `8fb5349d996dd00756e94c6335b776f4dd463cee41c94ede6f58d15437ac7482`
- `bin/masc_tui_render_schedule.mli`: `f3dcb457ad98d81eb68813f31bbd20d6356ee867520d6e36b17be2cf3a5f56d3`
- `changelog.d/50502.md`: `f1f6bc57e1d5d60bf9ceed046cb6c287c48d4f3c0bcfb4900f9a2f3f4534f1bd`
- `test/test_tui_render_schedule.ml`: `ddaca80aab01a4a50a32551503dd2e16296d4d5a76812d9ba2d69194587e01ff`
