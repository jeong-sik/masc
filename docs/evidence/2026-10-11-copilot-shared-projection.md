# Copilot shared conversation projection

Base: `649011a8e424372ed2fca6b6e3916a179194953e` (#42409).

The Dock kept a private text-only transcript and discarded exposed thinking and identified tool occurrences. It now uses the canonical Keeper threads, shared sending action and shared ChatTranscript. Copilot channel and workspace actor are acquired through the existing stream admission contract. The composer permits interleaved input.

## Measured checks

An isolated worktree at the base ran the same SSE fixture used against the repair: the Saying text became visible, then the canonical thinking assertion failed because no assistant trace existed. Against the repair that fixture passed together with 139 existing/updated focused tests (140 total, three files, Vitest 5.0.2). The temporary duplicate fixture was removed; the committed Copilot test retains this protocol scenario.

Previous focused run: copilot-dock and keeper-actions, 139 tests passed; TypeScript noEmit passed. These are mocked HTTP/SSE and DOM checks, not a live provider or browser screenshot.

A terminal receipt received before an authentication change remains authoritative. Unaccepted or superseded streams retain the shared action interruption semantics.

## Limits

No merge, formal GitHub approval, installation, named-provider continuity or live browser screenshot is established. The inherited shared action empty-terminal authored-text fallback remains a separate unresolved issue. Account cache isolation and pre-header proactive fetch abortion remain outside this change.

## Independent review responses

The initial candidate `1d1c8702745f01b1ba50423e021f7d56ec79226a` had two P2 findings: global internal/autonomous visibility preferences were bypassed, and default ungrouped rendering preserved thinking only in state without a visible timeline. DOM assertions reproduced both failures. The repair uses the existing typed visibility predicates and preferences and enables the shared turn-work grouping. The test opens the actual timeline and verifies exposed reasoning, and toggles internal/autonomous visibility without mutating stored history. The final two committed focused suites passed 140 tests. Initial autonomous body testing incorrectly assumed the preference opened an individual group; that fixture assumption was corrected to click the existing disclosure, without changing product behavior.

Historical independent findings: `/tmp/masc-copilot-shared-review-findings-20261011/report.md` (source review only).
