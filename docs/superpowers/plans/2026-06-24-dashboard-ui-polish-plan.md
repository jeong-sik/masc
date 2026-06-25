# Dashboard UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the crooked hover ellipsis on keeper roster rows and hide the empty “최근 활동” card in the agent detail overlay.

**Architecture:** Two independent, small UI changes in existing files: replace a text glyph with a centered SVG icon in the keeper roster, and conditionally render a SectionCard in the agent detail overlay. No new components or data-flow changes.

**Tech Stack:** Preact + TypeScript, `htm/preact`, `lucide-preact`, Tailwind-like utility classes + custom CSS in `dashboard/src/styles/keeper-v2/v2.css`, Vitest.

---

## File map

| File | Responsibility |
|------|----------------|
| `dashboard/src/components/keeper-workspace/keeper-workspace-roster.ts` | Renders keeper rows; contains the `⋯` button markup. |
| `dashboard/src/styles/keeper-v2/v2.css` | `.kp-more` styles. |
| `dashboard/src/components/agent-detail.ts` | Agent detail overlay; renders the “최근 활동” SectionCard. |

---

## Task 1: Replace roster ellipsis text with `MoreVertical` icon

**Files:**
- Modify: `dashboard/src/components/keeper-workspace/keeper-workspace-roster.ts:188-197`
- Modify: `dashboard/src/styles/keeper-v2/v2.css:1237-1244`
- Test: `dashboard/src/components/keeper-workspace/keeper-workspace-roster.test.ts`

- [ ] **Step 1: Add the `MoreVertical` import**

In `dashboard/src/components/keeper-workspace/keeper-workspace-roster.ts`, add to the existing `lucide-preact` import list (or create a new import line if no lucide import exists):

```ts
import { MoreVertical } from 'lucide-preact'
```

- [ ] **Step 2: Replace the button contents**

Change:

```ts
<button
  type="button"
  class="kp-more"
  aria-label=${`${keeper.name} 명령`}
  title="명령 메뉴"
  onClick=${(event: MouseEvent) => onMenu(keeper, event)}
  data-testid=${`kw-roster-menu-${keeper.name}`}
>
  <span aria-hidden="true">${'\u22EF'}</span>
</button>
```

To:

```ts
<button
  type="button"
  class="kp-more"
  aria-label=${`${keeper.name} 명령`}
  title="명령 메뉴"
  onClick=${(event: MouseEvent) => onMenu(keeper, event)}
  data-testid=${`kw-roster-menu-${keeper.name}`}
>
  <${MoreVertical} size=${16} focusable="false" aria-hidden="true" />
</button>
```

- [ ] **Step 3: Center the icon via CSS**

In `dashboard/src/styles/keeper-v2/v2.css`, replace the `.kp-more` block:

```css
.kp-more {
  position: absolute; right: 8px; top: 50%; transform: translateY(-50%);
  width: 24px; height: 24px; border-radius: var(--radius-sm); border: 1px solid var(--border-main);
  background: var(--bg-panel); color: var(--text-mid); cursor: pointer; font-size: 14px; line-height: 1;
  opacity: 0; transition: 0.14s; z-index: 2;
}
```

With:

```css
.kp-more {
  position: absolute; right: 8px; top: 50%; transform: translateY(-50%);
  width: 24px; height: 24px; border-radius: var(--radius-sm); border: 1px solid var(--border-main);
  background: var(--bg-panel); color: var(--text-mid); cursor: pointer;
  display: flex; align-items: center; justify-content: center; padding: 0;
  opacity: 0; transition: 0.14s; z-index: 2;
}
```

Keep the existing `.kp-row:hover .kp-more` and `.kp-more:hover` rules unchanged.

- [ ] **Step 4: Verify roster tests still pass**

Run:

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-memory-consolidation-wire/dashboard
pnpm test -- keeper-workspace-roster.test.ts
```

Expected: all tests pass.

- [ ] **Step 5: Handle lucide-preact test mock if needed**

If the test run fails with an error loading `lucide-preact`, add a mock to `keeper-workspace-roster.test.ts` before the component import:

```ts
vi.mock('lucide-preact', () => ({
  MoreVertical: () => null,
}))
```

Then re-run the test from Step 4.

- [ ] **Step 6: Commit Task 1**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-memory-consolidation-wire
git add dashboard/src/components/keeper-workspace/keeper-workspace-roster.ts dashboard/src/styles/keeper-v2/v2.css
git commit -m "fix(dashboard): center keeper roster hover menu icon with MoreVertical"
```

---

## Task 2: Hide empty “최근 활동” card in agent detail overlay

**Files:**
- Modify: `dashboard/src/components/agent-detail.ts:362-366`
- Test: `dashboard/src/components/agent-detail-state.test.ts` (no direct UI tests exist, but run to ensure imports still resolve)

- [ ] **Step 1: Make the SectionCard conditional**

In `dashboard/src/components/agent-detail.ts`, replace:

```ts
<${SectionCard} label="최근 활동">
  ${lines.length === 0
    ? html`<div class="h-full min-h-30"><${EmptyState} message="최근 활동 메시지가 없습니다" compact /></div>`
    : html`<div role="log" aria-label="최근 활동 로그" class="max-h-60 overflow-y-auto flex flex-col gap-2 pr-1 custom-scrollbar">${lines.map((line: string, idx: number) => html`<div key=${idx} class="v2-monitoring-row border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2.5 font-mono text-xs text-[var(--color-fg-primary)] leading-relaxed rounded-[var(--r-1)] hover:bg-[var(--color-bg-hover)] hover:border-[var(--color-border-strong)] transition-colors">${line}</div>`)}</div>`}
<//>
```

With:

```ts
${lines.length > 0
  ? html`
      <${SectionCard} label="최근 활동">
        <div role="log" aria-label="최근 활동 로그" class="max-h-60 overflow-y-auto flex flex-col gap-2 pr-1 custom-scrollbar">
          ${lines.map((line: string, idx: number) => html`<div key=${idx} class="v2-monitoring-row border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2.5 font-mono text-xs text-[var(--color-fg-primary)] leading-relaxed rounded-[var(--r-1)] hover:bg-[var(--color-bg-hover)] hover:border-[var(--color-border-strong)] transition-colors">${line}</div>`)}
        </div>
      <//>
    `
  : null}
```

- [ ] **Step 2: Verify agent-detail tests still pass**

Run:

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-memory-consolidation-wire/dashboard
pnpm test -- agent-detail-state.test.ts
```

Expected: all tests pass.

- [ ] **Step 3: Commit Task 2**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-memory-consolidation-wire
git add dashboard/src/components/agent-detail.ts
git commit -m "fix(dashboard): hide empty recent activity card in agent detail overlay"
```

---

## Task 3: Final verification

- [ ] **Step 1: Run type check**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-memory-consolidation-wire/dashboard
npx tsc --noEmit --pretty
```

Expected: no TypeScript errors.

- [ ] **Step 2: Run full dashboard test suite**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-memory-consolidation-wire/dashboard
pnpm test
```

Expected: all tests pass.

- [ ] **Step 3: Push branch**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/fix-memory-consolidation-wire
git push
```

---

## Spec coverage check

| Spec requirement | Task |
|------------------|------|
| Keeper roster hover ellipsis replaced with `MoreVertical` and centered | Task 1 |
| Existing menu behavior preserved | Task 1 (only button content + CSS changed) |
| “최근 활동” hidden when `lines.length === 0` | Task 2 |
| Data source unchanged | Not modified |
| agent-profile.ts untouched | Not modified |
