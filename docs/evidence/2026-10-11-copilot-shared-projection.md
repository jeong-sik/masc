# Copilot shared conversation projection

Base: `649011a8e424372ed2fca6b6e3916a179194953e` (#42409).

The Dock kept a private text-only transcript and discarded exposed thinking and identified tool occurrences. It now uses the canonical Keeper threads, shared sending action and shared ChatTranscript. Copilot channel and workspace actor are acquired through the existing stream admission contract. The composer permits interleaved input.

## Measured checks

An isolated worktree at the base ran the same SSE fixture used against the repair: the Saying text became visible, then the canonical thinking assertion failed because no assistant trace existed. Against the repair that fixture passed together with 139 existing/updated focused tests (140 total, three files, Vitest 5.0.2). The temporary duplicate fixture was removed; the committed Copilot test retains this protocol scenario.

Previous focused run: copilot-dock and keeper-actions, 139 tests passed; TypeScript noEmit passed. These are mocked HTTP/SSE and DOM checks, not a live provider or browser screenshot.

A terminal receipt received before an authentication change remains authoritative. Unaccepted or superseded streams retain the shared action interruption semantics.

## Limits

No merge, formal GitHub approval, installation, named-provider continuity or live browser screenshot is established. The inherited shared action empty-terminal authored-text fallback remains a separate unresolved issue. Account cache isolation and pre-header proactive fetch abortion remain outside this change.
