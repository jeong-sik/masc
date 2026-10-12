# Controlled Claude Agent retry screen witness

`test/test_tui_claude_agent_retry_pty.py` drives the actual compiled TUI against a controlled HTTP/SSE fixture. Its parent is the retry implementation at `a6141081c266d501a602296159b6c55e50e8e56a` (#41856). It does not invoke Claude, exercise provider authentication, or prove an installed/deployed runtime.

The runtime fixtures in [the retry contract](claude-agent-retry.md) own exact session, parent call, UUID and old-clear admission. This screen fixture supplies the already admitted typed native occurrence and retry/clear wire payloads. It deliberately does not inject a stale clear into the TUI and call that a runtime rejection test.

The user sends `엉... 아니야 진행해` once. The controlled provider supplies the answer `Answer remains unchanged.` and Thinking `Observed thinking.`. Every captured state requires all three bodies as separate unchanged physical rows. Metadata must remain outside those rows. The fixture supplies the normal roster and empty history/memory read contracts. Ordinary Enter's acceptance has `signalled: false`; no interruption target or control result is invented. Stream events receive actual fixture wall-clock timestamps, including terminal events.

## Frames and gates

Each state is captured at both **80×36** and **140×36** cells. A completed current screen with the new semantic fact releases the next producer event. Retained frames are reconstructed before matching (including `30s → 3s` digit updates). The harness's bounded failure waits are not stage transitions; no sleep or elapsed timeout makes a state pass. Width changes request complete redraws, and assertions are repeated against the exact captured redraw.

| Frame | Required visible fact while the Keeper turn remains in progress |
| --- | --- |
| provided-thinking | Supplied Thinking is visible; no content/response-end claim. |
| native-open | Exact native Agent row and provider elapsed 30s; native work owns the leading status. |
| retry-reported | Retry 1/3 and error status 529 are tool metadata. |
| heartbeat-decreased | Provider elapsed 3s replaces 30s while retry 1/3 remains. |
| notice-cleared-turn-open | Retry notice cleared, elapsed 3s retained, native call still running; no model-end claim. |
| second-retry | Retry 2/3 replaces the cleared notice. |
| native-ended-last-note | Tool result received with error flag unreported; historical retry 2/3 retained without a fabricated clear; original Thinking activity is visible again. |
| content-ended-turn-open | Both model content identities ended; model response has not ended. |
| response-ended-turn-open | Actual model response stop is visible; Keeper terminal is still withheld. |

Only after the final open-turn capture does the fixture release reply details and `RUN_FINISHED`. It waits for the turn progress row to disappear with the answer retained, then leaves the chat. Cleanup releases blocked producers on every exit.

## Evidence and execution boundary

The suite reads the executable's static `--build-commit`, requires its full embedded SHA, and emits `STUDIO_BINARY_COMMIT`, `STUDIO_BINARY_SHA256` and eighteen suite-tagged `STUDIO_CAPTURE` records on a successful run. It does not fall back to a caller's Git SHA when the binary has no stamp. Each record contains its terminal geometry, original ANSI frame bytes and independently reconstructed screen cells. `scripts/capture-tui-ci-frames.py --suite test_tui_claude_agent_retry_pty --suite-pass-marker 'TUI Claude Agent retry PTY: PASS'` is the existing screenshot replay consumer. The separate CI wrapper must compare the binary commit with the actual candidate checkout, rather than the workflow caller's `github.sha`. Source/run identity, actual binary digest, ANSI-frame digest, screenshot digest and replay geometry checks remain separate evidence layers. A failed suite cannot acquire a PASS claim from partial captures.

The Dune alias is `runtest-test_tui_claude_agent_retry_pty`; its dependencies include the actual chat helper import closure. Future CI selection must use the approved candidate/leader workflow. At this parent, `test.yml` contains only Surface/Usage/Primary/Navigation capture steps; automatic screenshot upload for this new suite requires a separate CI integration unit. The ordinary full runner log can retain the emitted records. This patch changes neither workflows nor global routing.

Author validation is Python syntax and diff checks only. No local build, HTTP binding, PTY run, live provider call, screenshot generation or CI execution was performed. The frames above are intended assertions, not claimed captures.
