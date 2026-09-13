# Full native fd441 route and gesture observations

Native build 34733001958/source fd441 used the same native server, host and TUI;
actual full source identities and three binary digests are retained in bundle.json
and report.json. This is distinct from the preceding mixed-component controlled
bridge run. Old raw records are unchanged.

The Keeper run recorded seven outer calls, no errors, four compositions and five
retained scenes. The route revisited Alpha: Alpha → Gamma → Alpha → Beta.
Observed elapsed time was 45.244 seconds. The TUI audit records 55 complete frames
without operator input after Keeper start. This is route/continuity evidence,
not a fastest-path result or a causal performance comparison.

The original terminal answer is preserved unchanged, including its stray final
character. Independent semantic review found an unsupported inference that Gamma
QA depends on the accessibility/payload checks. Beta's Monday migration completion
is planned, not established as completed. Do not present this as perfect answer
accuracy. The 910 Skill revision was NOT loaded in this run.

startup-failure retains the earlier failed cohort report and server-startup text.
The successful harness used ROOT.resolve() as a workaround only; product repair
was still pending at capture time. It does not erase the failed startup result.

The gestures subdirectory preserves actual gesture capture and HTTP observations,
including stale-viewport rejection. TUI PNGs are terminal replays; firefox-final.png
is an actual separate Firefox screenshot. They are not atomic aligned captures.
No Slack session was used; Slack remains deferred.

Run `python3 audit.py` from any directory in a repository archive. It reuses
../compare_runs.py for typed/raw execution joins and verifies exact delivered JSON
slices against the five stored scene blobs and receipt references, plus checksums.
Semantic answer review remains manual. No token, login file, runtime/provider
configuration, previous package backup or complete provider trace is included.
