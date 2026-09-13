# Adverse review: uncommitted installed Chat probe change

Reviewed /tmp/masc-collaboration-resume-20260912/scripts/verify-installed-chat-edit.mjs diff and full script against actual AutonomousTurnGroup/AutonomousTurnRun render source.

No P1/P2 found in the reviewed delta.

- Actual source initializes autonomous group/run local state closed independently of global Tweaks. New loop clicks the matching aria-expanded=false real UI headers, then middle-history controls, without injecting fixture responses or forcing DOM state.
- Loop remains scoped to exact autonomous label and stops once the expected execution snapshot row exists or no further controls remain. Final target must still be exactly one rendered Edit record.
- New navigation receipt records what was clicked. Existing complete original-byte equality, API execution identity, artifact SHA, worker, patch reconstruction, installed file digest, errors and mobile overflow checks remain intact.
- Scope now explicitly conditions equality/reconstruction claims on probe_passed and rendered. Failed probes no longer assert successful original rendering in prose.
- History expansion and Tweaks selector changes correspond to actual rendered controls.

This is source review only. The parent owns live run session 86934; its success/failure was not assumed and no duplicate browser probe was started here.

Follow-up on nested collapse: ToolTraceCard's default is !liveTurn; completed turns are open in a fresh browser with no stored explicit collapse choice (primitives.ts:3774). ToolTraceStep mounts ChatEditEvidence outside its own open/hasBody conditional (line 3557), so args/result body collapse does not hide the snapshot component. A genuinely live timeline can remain closed; this source review does not assert the selected execution's current DOM state. Long traversal through unrelated older groups can explain latency but was not measured here.
