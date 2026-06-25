# Fusion Dashboard Wiring & Rich-Text Rendering Update — Implementation Plan

> **For agentic workers:** REQUIRED SUB-_SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the standalone Fusion Dashboard surface to expose backend metadata (preset, generation params), render prompts/answers with `RichContent`, and fix word-break/mobile consistency.

**Architecture:** Keep all changes inside the standalone Fusion surface (`dashboard/src/components/fusion/fusion-surface.ts` and its CSS) without touching the inline board evidence card. Extend the existing view model, add defensive normalizers, swap plain text for `RichContent`, and add a parameter chip block plus CSS word-break rules.

**Tech Stack:** Preact + htm, TypeScript, Vite/Vitest, CSS modules in `dashboard/src/styles/fusion-v2.css`.

---

## Scope check

This plan covers a single subsystem: the standalone Fusion surface. The inline board evidence card already uses `RichContent` and is out of scope. Backend timeout investigation is out of scope per the design doc.

## File structure

| File | Responsibility |
|------|----------------|
| `dashboard/src/components/fusion/fusion-surface.ts` | View model, normalizers, components, rendering. All runtime changes live here. |
| `dashboard/src/styles/fusion-v2.css` | SSOT styles for the standalone surface: parameter chips, word-break rules, mobile helpers. |
| `dashboard/src/components/fusion/fusion-surface.test.ts` | Unit tests for the new behavior. |

---

## Task 1: Extend view model and add parameter normalizer

**Files:**
- Modify: `dashboard/src/components/fusion/fusion-surface.ts`

### Step 1.1: Add `FusionRunParams` interface and update `FusionRunView`

Insert after the `FusionUsage` interface (around line 95):

```ts
interface FusionRunParams {
  temperature: number | null
  topP: number | null
  topK: number | null
  maxTokens: number | null
}
```

Update `FusionRunView` (around line 97):

```ts
interface FusionRunView {
  runId: string
  boardPostId: string
  keeperName: string
  title: string
  question: string
  status: FusionRunStatus
  tone: FusionTone
  panel: FusionPanelEntry[]
  judge: FusionJudge
  judges: FusionJudgeNode[]
  usage: FusionUsage
  preset: string | null
  params: FusionRunParams
  createdAt: string
  updatedAt: string
}
```

### Step 1.2: Add `normalizeParams` helper

Insert after `normalizeUsage` (around line 245):

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

### Step 1.3: Update `fusionRunFromPost` to populate `preset` and `params`

Inside `fusionRunFromPost`, after `const usage = normalizeUsage(meta, panel)` add:

```ts
  const params = normalizeParams(meta)
```

And add `preset: null` and `params` to the returned object:

```ts
  return {
    runId,
    boardPostId: post.id,
    keeperName: keeperNameFor(post),
    title: post.title || `Fusion run ${runId}`,
    question,
    status,
    tone,
    panel,
    judge,
    judges,
    usage,
    preset: null,
    params,
    createdAt: post.created_at,
    updatedAt: post.updated_at || post.created_at,
  }
```

### Step 1.4: Type check

Run:

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx tsc --noEmit --pretty
```

Expected: no type errors.

---

## Task 2: Wire preset from the registry

**Files:**
- Modify: `dashboard/src/components/fusion/fusion-surface.ts`

### Step 2.1: Add `findPreset` helper

Insert before `FusionRunDetail` (around line 688):

```ts
function findPreset(runId: string): string | null {
  return fusionRuns.value.find(run => run.runId === runId)?.preset ?? null
}
```

### Step 2.2: Compute preset inside `FusionRunDetail`

Inside `FusionRunDetail`, after the existing destructurings add:

```ts
  const preset = run.preset ?? findPreset(run.runId)
```

### Step 2.3: Replace the stub preset chip

Replace lines 700-702:

```ts
          <span class="fus-preset" title="runtime.toml [fusion.presets.*]" data-stub="preset not joined into board-derived run view (registry-only field)">preset · n/a</span>
```

with:

```ts
          ${preset ? html`<span class="fus-preset" title="runtime.toml [fusion.presets.*]">preset · ${preset}</span>` : null}
```

### Step 2.4: Add a test for preset wiring

In `dashboard/src/components/fusion/fusion-surface.test.ts`, add inside the `FusionSurface` describe block:

```ts
  it('renders preset from registry when board meta does not carry it', () => {
    fusionRuns.value = [
      {
        runId: 'fus-1',
        keeper: 'sangsu',
        preset: 'balanced',
        startedAt: 1_780_000_000,
        status: 'running',
      },
    ]
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-fus-1',
        title: 'Fusion deliberation (run fus-1): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-1',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(detail?.textContent).toContain('preset · balanced')
    expect(detail?.textContent).not.toContain('preset · n/a')
  })
```

### Step 2.5: Run the new test

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx vitest run src/components/fusion/fusion-surface.test.ts -t "renders preset from registry"
```

Expected: PASS.

---

## Task 3: Add generation parameter UI

**Files:**
- Modify: `dashboard/src/components/fusion/fusion-surface.ts`
- Modify: `dashboard/src/styles/fusion-v2.css`

### Step 3.1: Add `paramChip` helper

Insert before `FusionRunDetail`:

```ts
function paramChip(label: string, value: number | null): ReturnType<typeof html> | null {
  if (value === null) return null
  return html`<span class="fus-param"><span class="k">${label}</span><span class="v">${value}</span></span>`
}

function hasParams(params: FusionRunParams): boolean {
  return params.temperature !== null
    || params.topP !== null
    || params.topK !== null
    || params.maxTokens !== null
}
```

### Step 3.2: Add the parameters block to `FusionRunDetail`

Insert after `<${FusionPipelineStrip} run=${run} />` (around line 722):

```ts
      ${hasParams(run.params)
        ? html`
            <div class="fus-block">
              <div class="fus-block-lbl">생성 파라미터</div>
              <div class="fus-params">
                ${paramChip('temperature', run.params.temperature)}
                ${paramChip('top_p', run.params.topP)}
                ${paramChip('top_k', run.params.topK)}
                ${paramChip('max_tokens', run.params.maxTokens)}
              </div>
            </div>
          `
        : null}
```

### Step 3.3: Add CSS for parameter chips

Append to `dashboard/src/styles/fusion-v2.css`:

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

### Step 3.4: Add a test for parameter rendering

In `dashboard/src/components/fusion/fusion-surface.test.ts`:

```ts
  it('renders generation parameters when present in board meta', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-params',
        title: 'Fusion deliberation (run fus-params): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-params',
          question: 'Which path?',
          temperature: 0.7,
          top_p: 0.95,
          top_k: 40,
          max_tokens: 2048,
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(detail?.textContent).toContain('temperature')
    expect(detail?.textContent).toContain('0.7')
    expect(detail?.textContent).toContain('top_p')
    expect(detail?.textContent).toContain('0.95')
    expect(detail?.textContent).toContain('top_k')
    expect(detail?.textContent).toContain('40')
    expect(detail?.textContent).toContain('max_tokens')
    expect(detail?.textContent).toContain('2048')
  })

  it('hides the generation parameters block when no params are present', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-no-params',
        title: 'Fusion deliberation (run fus-no-params): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-no-params',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const detail = container.querySelector('[data-testid="fusion-detail"]')
    expect(detail?.textContent).not.toContain('생성 파라미터')
  })
```

### Step 3.5: Run tests

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx vitest run src/components/fusion/fusion-surface.test.ts -t "generation parameters"
```

Expected: both tests PASS.

---

## Task 4: Render deliberation prompt with RichContent

**Files:**
- Modify: `dashboard/src/components/fusion/fusion-surface.ts`

### Step 4.1: Import `RichContent`

Add to the imports at the top:

```ts
import { RichContent } from '../common/rich-content'
```

### Step 4.2: Replace prompt plain text

Replace:

```ts
      <div class="fus-block">
        <div class="fus-block-lbl">심의 프롬프트</div>
        <div class="fus-prompt">${run.question}</div>
      </div>
```

with:

```ts
      <div class="fus-block">
        <div class="fus-block-lbl">심의 프롬프트</div>
        <div class="fus-prompt"><${RichContent} text=${run.question} previewLimit=${0} /></div>
      </div>
```

### Step 4.3: Add a test

```ts
  it('renders the deliberation prompt as rich content', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-rich-prompt',
        title: 'Fusion deliberation (run fus-rich-prompt): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-rich-prompt',
          question: 'Check **this** [link](https://example.com).',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'OK.' }],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Done.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const prompt = container.querySelector('[data-testid="fusion-detail"] .fus-prompt')
    expect(prompt?.querySelector('.markdown-body')).not.toBeNull()
    expect(prompt?.textContent).toContain('this')
    expect(prompt?.textContent).toContain('link')
  })
```

### Step 4.4: Run test

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx vitest run src/components/fusion/fusion-surface.test.ts -t "deliberation prompt as rich content"
```

Expected: PASS.

---

## Task 5: Render panel answers with RichContent

**Files:**
- Modify: `dashboard/src/components/fusion/fusion-surface.ts`

### Step 5.1: Update `FusionPanelCard`

Inside `FusionPanelCard`, change the body rendering section (around line 519-531) from:

```ts
      ${failed
        ? null
        : html`
            <div
              class=${`fus-pans ${open ? 'open' : ''}`}
              role="button"
              tabIndex=${0}
              title=${open ? '접기' : '펼치기'}
              onClick=${() => setOpen(prev => !prev)}
              onKeyDown=${(event: KeyboardEvent) => {
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault()
                  setOpen(prev => !prev)
                }
              }}
            >${body}</div>
          `}
```

to:

```ts
      ${failed
        ? html`<div class="fus-pans failed">${body}</div>`
        : html`
            <div
              class=${`fus-pans ${open ? 'open' : ''}`}
              role="button"
              tabIndex=${0}
              title=${open ? '접기' : '펼치기'}
              onClick=${() => setOpen(prev => !prev)}
              onKeyDown=${(event: KeyboardEvent) => {
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault()
                  setOpen(prev => !prev)
                }
              }}
            ><${RichContent} text=${body} previewLimit=${0} /></div>
          `}
```

### Step 5.2: Add CSS for failed panel body

Add to `dashboard/src/styles/fusion-v2.css`:

```css
.v2-fusion-surface .fus-pans.failed {
  color: var(--bad-light);
  cursor: default;
}
```

### Step 5.3: Add a test

```ts
  it('renders panel answers as rich content', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-rich-panel',
        title: 'Fusion deliberation (run fus-rich-panel): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-rich-panel',
          question: 'Which path?',
          panel: [
            {
              model: 'gpt-5',
              status: 'answered',
              answer: 'Use **canary** first.',
            },
          ],
          judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'Ship canary.' },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const panel = container.querySelector('.fus-panel-card')
    expect(panel?.querySelector('.markdown-body')).not.toBeNull()
    expect(panel?.textContent).toContain('canary')
  })
```

### Step 5.4: Run test

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx vitest run src/components/fusion/fusion-surface.test.ts -t "panel answers as rich content"
```

Expected: PASS.

---

## Task 6: Render judge evidence with RichContent

**Files:**
- Modify: `dashboard/src/components/fusion/fusion-surface.ts`

### Step 6.1: Update `FusionJudgeEvidence`

Replace all occurrences where long text is rendered directly inside `FusionJudgeEvidence`.

For consensus claims (around line 571-575):

```ts
            <div class="fus-claim" key=${`consensus-${index}`}>
              <p><${RichContent} text=${claim.text} previewLimit=${0} /></p>
              <${FusionModelChips} models=${claim.models} />
            </div>
```

For contradiction stances (around line 588-589):

```ts
                      <span class="fus-pos-s"><${RichContent} text=${position.stance} previewLimit=${0} /></span>
```

For coverage missing text (around line 611):

```ts
                      <span class="fus-gap-miss"><${RichContent} text=${gap.missing} previewLimit=${0} /></span>
```

For unique insights (around line 624-626):

```ts
                  <div class="fus-insight" key=${`insight-${index}`}>
                    <p><${RichContent} text=${insight.text} previewLimit=${0} /></p>
                    ${insight.model ? html`<span class="fus-mchip mono">${insight.model}</span>` : null}
                  </div>
```

For blind spots and missing inputs (around lines 637 and 646):

```ts
<ul class="fus-blind">${judge.blindSpots.map(item => html`<li key=${item}><${RichContent} text=${item} previewLimit=${0} /></li>`)}</ul>
```

and:

```ts
<ul class="fus-blind">${judge.missingInputs.map(item => html`<li key=${item}><${RichContent} text=${item} previewLimit=${0} /></li>`)}</ul>
```

### Step 6.2: Add a test

```ts
  it('renders judge evidence text as rich content', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-rich-judge',
        title: 'Fusion deliberation (run fus-rich-judge): answer',
        meta: {
          source: 'fusion',
          run_id: 'fus-rich-judge',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: {
            status: 'synthesized',
            decision: 'answer',
            resolved_answer: 'Ship canary.',
            consensus: [{ text: '**Canary** is safer.', models: ['gpt-5'] }],
          },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const evidence = container.querySelector('[data-testid="fusion-judge-evidence"]')
    expect(evidence?.querySelector('.markdown-body')).not.toBeNull()
    expect(evidence?.textContent).toContain('Canary')
  })
```

### Step 6.3: Run test

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx vitest run src/components/fusion/fusion-surface.test.ts -t "judge evidence text as rich content"
```

Expected: PASS.

---

## Task 7: Render resolved answer and recommendation rationale with RichContent

**Files:**
- Modify: `dashboard/src/components/fusion/fusion-surface.ts`

### Step 7.1: Update resolved answer

Replace (around line 789):

```ts
        <p class="fus-resolved-body">${resolved}</p>
```

with:

```ts
        <p class="fus-resolved-body"><${RichContent} text=${resolved} previewLimit=${0} /></p>
```

### Step 7.2: Update recommendation rationale

Replace (around line 791):

```ts
        ${run.judge.recommendation?.rationale
          ? html`<p class="fus-rec-rationale"><span class="k">근거</span>${run.judge.recommendation.rationale}</p>`
          : null}
```

with:

```ts
        ${run.judge.recommendation?.rationale
          ? html`<p class="fus-rec-rationale"><span class="k">근거</span><${RichContent} text=${run.judge.recommendation.rationale} previewLimit=${0} /></p>`
          : null}
```

### Step 7.3: Add a test

```ts
  it('renders resolved answer and recommendation rationale as rich content', () => {
    fusionBoardPosts.value = [
      boardPost({
        id: 'post-rich-resolved',
        title: 'Fusion deliberation (run fus-rich-resolved): recommend',
        meta: {
          source: 'fusion',
          run_id: 'fus-rich-resolved',
          question: 'Which path?',
          panel: [{ model: 'gpt-5', status: 'answered', answer: 'Canary.' }],
          judge: {
            status: 'synthesized',
            decision: 'recommend',
            resolved_answer: 'Ship **canary**.',
            recommend: {
              action: 'publish note',
              rationale: 'Because **rollback** is covered.',
            },
          },
        },
      }),
    ]

    render(html`<${FusionSurface} />`, container)

    const resolved = container.querySelector('.fus-resolved-body')
    expect(resolved?.querySelector('.markdown-body')).not.toBeNull()
    expect(resolved?.textContent).toContain('canary')

    const rationale = container.querySelector('.fus-rec-rationale')
    expect(rationale?.querySelector('.markdown-body')).not.toBeNull()
    expect(rationale?.textContent).toContain('rollback')
  })
```

### Step 7.4: Run test

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx vitest run src/components/fusion/fusion-surface.test.ts -t "resolved answer and recommendation rationale"
```

Expected: PASS.

---

## Task 8: Unify word-break rules

**Files:**
- Modify: `dashboard/src/styles/fusion-v2.css`

### Step 8.1: Add shared word-break rule

Append to `dashboard/src/styles/fusion-v2.css`:

```css
/* Unified long-text wrapping for the standalone Fusion surface.
   Keep CJK readability while allowing arbitrary identifiers/URLs to break. */
.v2-fusion-surface .fus-prompt,
.v2-fusion-surface .fus-resolved-body,
.v2-fusion-surface .fus-panel-body,
.v2-fusion-surface .fus-jrow,
.v2-fusion-surface .fus-gap-miss,
.v2-fusion-surface .fus-pos-s,
.v2-fusion-surface .fus-claim p,
.v2-fusion-surface .fus-insight p,
.v2-fusion-surface .fus-blind li,
.v2-fusion-surface .fus-missing li,
.v2-fusion-surface .fus-rec-rationale .markdown-body {
  overflow-wrap: anywhere;
  text-wrap: pretty;
}
```

### Step 8.2: Align KPI value

`.fus-kpi-v` already has `overflow-wrap: anywhere;`. Add `text-wrap: pretty;` to keep it consistent:

```css
.v2-fusion-surface .fus-kpi-v {
  margin-top: 4px;
  color: var(--fus-text);
  font-size: 22px;
  font-weight: 760;
  line-height: 1.05;
  overflow-wrap: anywhere;
  text-wrap: pretty;
}
```

### Step 8.3: Verify visually (manual)

Run the dashboard locally:

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npm run dev
```

Open the Fusion surface with a run that contains long unbroken strings (e.g., URLs, file paths). Confirm text wraps without horizontal overflow on both desktop and mobile viewport (use browser DevTools).

---

## Task 9: Run full test suite and type check

**Files:**
- Modify: none (verification only)

### Step 9.1: Type check

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx tsc --noEmit --pretty
```

Expected: no errors.

### Step 9.2: Fusion surface tests

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx vitest run src/components/fusion/fusion-surface.test.ts
```

Expected: all tests PASS.

### Step 9.3: Optional broader test run

```bash
cd ~/me/workspace/yousleepwhen/masc/dashboard && npx vitest run src/components/fusion/
```

Expected: all tests PASS.

---

## Self-review

### Spec coverage

| Spec requirement | Task |
|------------------|------|
| Extend `FusionRunView` with params and preset | Task 1 |
| Wire preset from registry, remove stub | Task 2 |
| Render generation params as chips | Task 3 |
| Render deliberation prompt as rich text | Task 4 |
| Render panel answers as rich text | Task 5 |
| Render judge evidence as rich text | Task 6 |
| Render resolved answer / rationale as rich text | Task 7 |
| Unify word-break rules | Task 8 |
| Mobile remains usable | Tasks 3, 8 (flex-wrap, existing media queries) |
| Tests + type check | Task 9 |

### Placeholder scan

No TBD/TODO, no vague "add appropriate" steps. Each step includes exact file paths, code, commands, and expected output.

### Type consistency

- `FusionRunView.preset` is `string | null` everywhere.
- `FusionRunParams` fields are `number | null`.
- `paramChip` accepts `number | null`.
- `RichContent` `text` prop is always `string` (fallback strings provided).

---

## Execution handoff

Plan complete and saved to `docs/design/2026-06-24-fusion-dashboard-wiring-rich-text-plan.md`.

Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
