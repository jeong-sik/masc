# Fusion Dashboard Wiring & Rich-Text Rendering Update

- Date: 2026-06-24
- Author: kimi-code
- Scope: `~/me/workspace/yousleepwhen/masc/dashboard` (runtime `<MASC_BASE_PATH>/.masc`)
- Status: Approved for implementation

## Goal

Update the standalone Fusion Dashboard surface so that it keeps up with the latest Fusion backend metadata, renders deliberation prompts and panel/judge answers as rich text, exposes generation parameters, and remains consistent on mobile with predictable word-breaking.

## Out of scope

- Backend timeout / panel failure root-cause analysis (separate issue).
- Full unification of the standalone Fusion surface and the inline board evidence card.
- Prototype-v2 design-system parity sweep.

## Background

Recent Fusion backend work (RFC-0284 judge observation record, judge-of-judges topology, etc.) added new fields to board posts. The inline board evidence card (`dashboard/src/components/board/fusion-evidence.ts`) already consumes `judges`, uses `RichContent`, and has a compact Tailwind-like markup. The standalone Fusion surface (`dashboard/src/components/fusion/fusion-surface.ts`) lags behind: it still renders prompts/answers as plain text, carries a `preset · n/a` stub, and does not expose generation parameters. Its styles are split between `fusion-v2.css` and `keeper-v2/fusion.css`, causing word-break and mobile inconsistencies.

## Design

### 1. Data model

Extend `FusionRunView` and add a parameter type in `dashboard/src/components/fusion/fusion-surface.ts`:

```ts
interface FusionRunParams {
  temperature: number | null
  topP: number | null
  topK: number | null
  maxTokens: number | null
}

interface FusionRunView {
  // ...existing fields
  preset: string | null
  params: FusionRunParams
}
```

Add a normalizer:

```ts
function normalizeParams(meta: Record<string, unknown>): FusionRunParams {
  return {
    temperature: firstNumber(meta, ['temperature']),
    topP: firstNumber(meta, ['top_p', 'topP']),
    topK: firstNumber(meta, ['top_k', 'topK']),
    maxTokens: firstNumber(meta, ['max_tokens', 'maxTokens']),
  }
}
```

`preset` is currently registry-only. Derive it by looking up the same `runId` in `fusionRuns.value`; if absent, hide the preset chip instead of rendering a stub.

### 2. Rich-text rendering

Import `RichContent` from `../common/rich-content` and replace plain text in:

| Location | Current | Change |
|----------|---------|--------|
| Deliberation prompt (`fusion-surface.ts:741-742`) | `<div class="fus-prompt">${run.question}</div>` | `<div class="fus-prompt"><${RichContent} text=${run.question} previewLimit=${0} /></div>` |
| Panel answer (`FusionPanelCard`) | `<div class="fus-pans">${body}</div>` | Use `RichContent` when `entry.answer` is present; keep `entry.reason` plain. |
| Judge synthesis / consensus / contradictions / coverage / insights (`FusionJudgeEvidence`) | `<p>${text}</p>` | Wrap long text with `RichContent`. Short chips/labels stay plain. |
| Resolved answer (`fusion-surface.ts:789`) | `<p class="fus-resolved-body">${resolved}</p>` | `<p class="fus-resolved-body"><${RichContent} text=${resolved} previewLimit=${0} /></p>` |
| Recommendation rationale (`fusion-surface.ts:791`) | Plain text span | `RichContent` |

`RichContent` already handles markdown and link previews. `previewLimit=${0}` disables link previews inside dense panels to avoid performance overhead.

### 3. Generation parameters UI

Add a new block in `FusionRunDetail`, placed after the pipeline strip:

```ts
<div class="fus-block">
  <div class="fus-block-lbl">생성 파라미터</div>
  <div class="fus-params">
    ${paramChip('temperature', run.params.temperature)}
    ${paramChip('top_p', run.params.topP)}
    ${paramChip('top_k', run.params.topK)}
    ${paramChip('max_tokens', run.params.maxTokens)}
  </div>
</div>
```

`paramChip` returns `null` when the value is `null`. If all values are `null`, the entire block is hidden.

### 4. CSS / word-break consistency

Treat `dashboard/src/styles/fusion-v2.css` as the SSOT for the standalone surface. Make no changes to `keeper-v2/fusion.css`.

Add a single shared rule for long text containers:

```css
.v2-fusion-surface .fus-prompt,
.v2-fusion-surface .fus-resolved-body,
.v2-fusion-surface .fus-panel-body,
.v2-fusion-surface .fus-jrow,
.v2-fusion-surface .fus-gap-miss,
.v2-fusion-surface .fus-pos-s,
.v2-fusion-surface .fus-claim p,
.v2-fusion-surface .fus-insight p,
.v2-fusion-surface .fus-blind li,
.v2-fusion-surface .fus-missing li {
  overflow-wrap: anywhere;
  text-wrap: pretty;
}
```

Also align `.fus-kpi-v` with the same rule (it already uses `overflow-wrap: anywhere`).

Add parameter chip styling:

```css
.v2-fusion-surface .fus-params {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.v2-fusion-surface .fus-param {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  border: 1px solid var(--fus-line);
  border-radius: var(--r-1);
  background: var(--fus-panel-strong);
  padding: 4px 8px;
  font-size: 11px;
}

.v2-fusion-surface .fus-param .k {
  color: var(--fus-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  text-transform: uppercase;
  font-size: 9.5px;
}

.v2-fusion-surface .fus-param .v {
  color: var(--fus-text);
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
```

### 5. Mobile refinements

Existing media queries handle most collapse. Verify and tighten:

- `.fus-params` wraps via `flex-wrap: wrap`.
- `.fus-pipe` already uses `flex-wrap: wrap`.
- `.fus-panel-grid` already collapses via `repeat(auto-fit, minmax(248px, 1fr))`.
- No additional breakpoint needed.

### 6. Error / empty states

- If all params are `null`, omit the parameters block.
- If `preset` lookup fails, omit the preset chip.
- `RichContent` returns `null` for empty strings, so guard clauses around `body`/`resolved` remain valid.

### 7. Testing

Update `dashboard/src/components/fusion/fusion-surface.test.ts`:

- Assert that the deliberation prompt container contains a `.markdown-body` child.
- Assert that a panel answer renders inside `RichContent` (`.markdown-body`) when `entry.answer` is present.
- Assert that parameter chips render for `temperature`, `top_p`, `top_k`, `max_tokens`.
- Assert that the `preset` stub is gone and the preset chip renders only when data is present.
- Run `npx tsc --noEmit --pretty` from the dashboard root and the affected unit tests.

## Files to change

1. `dashboard/src/components/fusion/fusion-surface.ts`
2. `dashboard/src/styles/fusion-v2.css`
3. `dashboard/src/components/fusion/fusion-surface.test.ts`

## Acceptance criteria

- [ ] `preset · n/a` stub is removed; preset renders only when available.
- [ ] Deliberation prompt, panel answers, judge evidence, and resolved answer render with `RichContent`.
- [ ] `temperature`, `top_p`, `top_k`, `max_tokens` are displayed as chips when present.
- [ ] Long text wraps consistently via `overflow-wrap: anywhere; text-wrap: pretty;`.
- [ ] Mobile layout remains usable (parameters wrap, panels collapse, pipeline wraps).
- [ ] Existing tests pass and new assertions are added.
- [ ] Type check passes (`npx tsc --noEmit --pretty`).
