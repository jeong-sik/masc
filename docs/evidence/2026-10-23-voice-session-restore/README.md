# Voice session restore and activity · 2026-10-23

If a persisted realtime session loses its configured bridge endpoint, retain realtime intent and its original session/agent/voice/turn history as Suspended. Persisting it again must not turn it into a turn-based session. Endpoint configuration restores transport capability; explicit start resumes local activity. Neither proves a websocket/audio connection.

The public `Realtime_unavailable` state also suspends newly created and restarted sessions. Unknown/missing persisted conversation modes, blank session IDs and filename/agent mismatches are rejected, while valid identity bytes and endpoint redaction are retained.

- [Final source manifest](source-manifest.json): five files, source head `0af6299700b262529884cc34be10ea8c959270cd`, base `fe1e8f7292e2f1aedd12e39cc6a872679fe2a591`. Later changelog/evidence-only changes are not silently certified by this earlier head.
- [Initial source FAIL](initial-source-review.md) and [original reviewer-message capture](initial-independent-finding.json) preserve the actual P2: Keeper's response used session existence as activity even for a suspended session.
- [Final independent SOURCE PASS](final-source-review.md) / [machine-readable report](final-source-review.json): the shared typed `session_is_active` getter is used by manager and actual Keeper consumer. Authored tests exercise both persisted lifecycle and real Keeper handler responses, including suspended → configured-but-inactive → explicit start active.
- [Independent parser checks](independent-parser-checks.json) and author parser checks passed only. Authored tests have not run locally. Requested focused targets are `test_voice_session_manager` and `test_voice_runtime_overlay`; compile/test results, when available, must be attached to their actual head.

The original proposal was music-sensei's artifact `artifact-9ae98bdab00958b131cf9957b5ffdb0f` (body SHA256 `cc4d195c35fe0573126c8914cb9606b551be3c427071c9d578317394a9e5da08`). The integrator and independent reviewer read its actual contents; this private artifact is provenance, not a public runtime proof. The public diff and reports provide the reviewable change.

No local Dune build, OCaml typing/test execution, device/provider/audio operation, runtime installation or visible TUI/dashboard observation occurred here. This is a bounded E09 session-state repair. TTS/STT/player/device ownership, actual input/output and Addon cleanup remain under the original E09 completion criterion.
