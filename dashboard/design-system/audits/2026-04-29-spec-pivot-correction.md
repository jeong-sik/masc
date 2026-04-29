# Design Spec Correction — 2026-04-29

- **Trigger**: external spec review at `~/Downloads/masc-mcp-design-system-spec.md`
  (175 KB, 2026-04-29).
- **Scope**: spot corrections where the spec's static analysis diverges
  from runtime ground truth. Spec authors did not have access to the
  full Two-Tier SSOT context recorded in `CSS-ARCHITECTURE.md`.
- **Action**: this memo records the corrections so subsequent v2 Iter
  PRs (especially Iter 2/3 absorption) plan against accurate baselines.

---

## 1. `--button-*` Role token "undefined variable" diagnosis (spec §2.3.1)

### Spec claim

> "buttons reference undefined variables `--accent-12`, `--white-4`,
> `--bad-10` … browser evaluates `var(--accent-12)` to `initial` …
> button visual representation is completely destroyed."

### Ground truth

`--accent-12`, `--accent-20`, `--accent-30`, `--white-4`, `--white-6`,
`--white-8`, `--bad-10`, `--bad-20`, `--bad-30`, `--ok-10`, `--ok-20`,
`--warn-14`, `--warn-24` — all 13 names — **are defined**, in
`dashboard/src/styles/variables.css`. They are not in `tokens/source.ts`,
which is why a search restricted to the SSOT-1 files appears to find
nothing.

```css
/* dashboard/src/styles/variables.css */
--accent-12: rgba(71, 184, 255, 0.12);
--white-4:   var(--white-5);     /* alias chain */
--bad-10:    rgba(239, 68, 68, 0.10);
/* … */
```

CSS does not evaluate these to `initial`. Buttons render with the
`variables.css` (SSOT-2) values at runtime.

### What is *actually* happening

`CSS-ARCHITECTURE.md` documents the design intentionally: a
**Two-Tier SSOT**.

- **SSOT-1** — `tokens/source.ts` — *Muted Brass Canon*. Drives
  preview, Bonsai, codegen, the brass-only "active state" contract.
- **SSOT-2** — `dashboard/src/styles/variables.css` — *Bright
  Live-Surface*. Hand-authored Tailwind 400/500 saturation for the
  live Preact production surface.

`--button-primary-bg → var(--accent-12)` resolves to a *blue*
(`rgba(71, 184, 255, 0.12)`), not the brass `--brass-1`. So the
visual rendering is **wrong relative to SKILL.md's brass-only active
rule**, not relative to CSS evaluation. The spec correctly identified
a real defect, but mis-attributed the mechanism.

### Implication for fix strategy

The spec recommends "Method A: define `--accent-12` in source.ts; or
Method B: redirect `--button-primary-bg` to `--brass-1`". With the
correct mechanism in mind:

- **Method A is harmful** if the value copied is the variables.css
  blue. That entrenches the drift inside SSOT-1, conflicting with the
  brass canon.
- **Method B aligns with SKILL.md** and the Phase 0 audit
  (`2026-04-28-production-css-drift.md`) absorption goal: stage 1
  picks brass-side values and lets variables.css absorb downward
  during Iter 2/3.

The component-level role-token migration in flight (cycles 47–50:
`--toast-bg`, `--input-bg-*`, `--dialog-panel-bg`, `--button-*` to
follow) is the right vehicle. The role-token alias values should
target the brass canon — `var(--brass-soft)`, `var(--brass-1)`,
`var(--state-active-bg)` — not the variables.css blues.

## 2. `variables.css` hex count (spec implicit, audit §3 explicit)

Spec assumes `tokens/source.ts` is the only SSOT. The Phase 0 audit
already corrects this: 40 hexes in `variables.css` plus 32 in
`paper-theme.css` = **72 hexes in SSOT-2**, distinct from the 130+ raw
tokens in SSOT-1. Iter 2/3 absorbs the 72 SSOT-2 hexes into SSOT-1.

For the spec roadmap (§5.1.3), this means:

- "72 hex absorption" is real and matches Phase 0.
- After absorption, `variables.css` either disappears entirely
  (preferred — collapses the Two-Tier into one) or retains only
  *role-aware* aliases (`--white-4 → var(--bg-2)` etc.) with no
  hexes of its own.
- The brass canon must own the absorbed values. Where SKILL.md
  conflicts with the legacy blue palette, brass wins.

## 3. Spec roadmap §5.1 stage 1 — concrete first PRs

The spec recommends three sub-tasks for stage 1:

1. §5.1.1 button bug fix → handled by component-level role-token
   migration cycle (active 2026-04-29).
2. §5.1.2 IDE Chrome tokens → first PR opens 2026-04-29 with
   `feature/ds-v2-ide-chrome-tokens` (tab/sidebar/panel/terminal,
   25 tokens). All values target the brass canon (`--bg-N`, `--fg-N`,
   `--brass-N`, `--line-N`) — no variables.css dependency.
3. §5.1.3 variables.css/paper-theme.css absorption → matches Iter 2/3
   in `20m-keen-giraffe.md`; in-flight via `chore/bg-white-*-migrate`
   family.

This memo unblocks the first IDE Chrome PR by clarifying that the
chrome tokens should not pull variables.css values.

## 4. Spec roadmap §5.2 — RFC 0003 Roving Tabindex

Spec §5.2.1 names "FocusScope extension" and "separate primitive" as
two design options for Roving Tabindex, recommends the latter, then
defers to RFC 0003 — which did not exist. Drafted today as
`dashboard/design-system/RFC/0003-roving-tabindex.md`. That RFC pulls
the spec recommendation through to a concrete API surface and test
plan; subsequent stage-2 component PRs (Tabs, Tree, Toolbar) consume
the RFC.

## 5. What the spec gets right

The spec is broadly accurate on:

- Token tier discipline (Raw → Semantic → Role).
- Headless completeness % (3 primitives, 6 ARIA patterns, ~52% overall).
- cockpit ↔ production drift.
- Strangler Fig progress (Iter 1 done, Iter 2 in flight).
- 5-stage roadmap shape (token boost → P0 headless → P1 → agent
  collab → cockpit sync).

These sections informed both the IDE Chrome token PR and the RFC 0003
draft. The corrections in §1–§2 above narrow the failure mode of the
button defect; they do not invalidate the roadmap.

## 6. References

- `~/Downloads/masc-mcp-design-system-spec.md` — external spec
- `dashboard/design-system/CSS-ARCHITECTURE.md` — Two-Tier SSOT
- `dashboard/design-system/audits/2026-04-28-production-css-drift.md`
  — Phase 0 baseline (90 unique hex, 75.6% token ratio)
- `dashboard/design-system/audits/2026-04-28-v2-pivot-audit.md`
  — Iter 0 audit
- `dashboard/design-system/SKILL.md` — brass-only active state rule
- `~/me/planning/claude-plans/20m-keen-giraffe.md` — v2 Iter 1–26
- `dashboard/design-system/RFC/0003-roving-tabindex.md` — drafted
  alongside this memo
