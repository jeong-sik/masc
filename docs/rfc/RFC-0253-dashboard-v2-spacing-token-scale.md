---
rfc: "0253"
title: "Dashboard keeper-v2 surfaces: canonical spacing/radius token scale + off-scale px remediation"
status: Draft
created: 2026-06-17
updated: 2026-06-17
author: vincent
supersedes: []
superseded_by: null
related: ["0168", "0170", "0174", "0204"]
implementation_prs: []
---

# RFC-0253 — Dashboard keeper-v2 spacing/radius token scale

## §0 Context — the finding

The keeper-v2 surface restyling (board, work, ide, memory, telemetry, connectors,
design-canvas, chat-blocks, primitives, indicators) tokenizes **color** correctly
(`var(--token)` throughout; near-zero raw `#hex`/`rgb()`), but encodes **spacing,
sizing, and radius as raw `px` literals** instead of design tokens.

Measured on `origin/main` (per file: total `px` literals / literals that match no
spacing token):

| file | px literals | off-scale (5/9/10/11/13/14/18px) |
|------|------------:|---------------------------------:|
| board-v2 | 137 | 67 |
| memory-v2 | 144 | 59 |
| chat-blocks-v2 | 115 | 19 |
| ide-v2 | 86 | 26 |
| work-v2 | 82 | 32 |
| primitives-v2 | 32 | 10 |
| indicators-v2 | 13 | 7 |
| **total** | **609** | **220** |

`board-v2` and `work-v2` are already merged; the rest are open surface PRs. The
fleet is generating these by transcribing a visual prototype's exact pixel values
(e.g. `padding: 14px 9px`, `padding: 11px 18px`, `gap: 4px 14px`) rather than
composing the spacing scale.

This matches two anti-patterns in `software-development.md`: **Magic Number** (a
literal that carries no semantic meaning) and **Scattered Hardcoded Defaults**
(the same value copy-pasted across files instead of a single SSOT token).

## §1 Why "just use the tokens" does not work mechanically

Two blockers make a mechanical px→token substitution impossible without a prior
decision:

### §1.1 The token scale is itself fragmented (4 overlapping scales)

| scale | values |
|-------|--------|
| `--space-1..8` (variables.css, tokens.generated.css) | 4/8/12/16/**24**/32/48/64 |
| `--sp-1..8` (+`--sp-0h:2`, `--sp-1h:6`) | 4/8/12/16/**20**/24/32/40 |
| `--r-0..6` (tokens.css) | 2/3/5/8/12/20/28 |
| `--radius-xs..xl` | tokens.generated: 2/4/6/12/24 vs variables.css: 2/3/4/6/8 — **conflicting** |

`--space-*` and `--sp-*` diverge at step 5 (24 vs 20). The two radius definitions
disagree on `--radius-md` (6px vs 4px). There is no single canonical scale to map
to.

### §1.2 The v2 px values are off every scale

| px used by v2 | nearest token | issue |
|---------------|---------------|-------|
| 2, 4, 6, 8, 12 | `--sp-0h/1/1h/2/3` | maps cleanly |
| 5, 9, 11, 13 | none | off-scale, no token exists |
| 10 | `--sp-2`(8) vs `--sp-3`(12) | ±2px tie |
| 14 | `--sp-3`(12) vs `--sp-4`(16) | ±2px tie |
| 18 | `--sp-4`(16) vs `--sp-5`(20) | ±2px tie |

220 of 609 literals (36%) fall in the off-scale / tie rows. Tokenizing them
requires **rounding to a scale**, which is a small but real visual change to
designs that have already been merged and presumably visually approved. That is a
decision, not a refactor — hence this RFC.

## §2 Decision

### §2.1 Canonical spacing scale

Adopt `--sp-*` as the single canonical spacing scale and deprecate `--space-*`:

```
--sp-0h: 2px   --sp-1: 4px   --sp-1h: 6px   --sp-2: 8px
--sp-3: 12px   --sp-4: 16px  --sp-5: 20px   --sp-6: 24px
--sp-7: 32px   --sp-8: 40px
```

Rationale: `--sp-*` is the more granular scale (it has the half-steps `--sp-0h`,
`--sp-1h`) and already carries the density-aware composite tokens (`--sp-stack`,
`--sp-section`, `--sp-gutter`). `--space-*` becomes an alias layer
(`--space-N: var(--sp-equivalent)`) during migration, then is removed.

### §2.2 Canonical radius scale

Collapse `--r-*` and `--radius-*` to one set, resolving the `--radius-md` conflict.
Proposed: keep `--radius-xs/sm/md/lg/xl/pill` as the public names, defined from a
single source. Exact values to be fixed in implementation against the prototype's
intended corner radii.

### §2.3 Rounding rule for off-scale values

Round each off-scale px to the nearest canonical step; on a ±2px tie, round **down**
(tighter spacing, preserves density). Documented mapping:

```
5px → --sp-1 (4)    9px → --sp-2 (8)     10px → --sp-2 (8)
11px → --sp-3 (12)  13px → --sp-3 (12)   14px → --sp-3 (12)
18px → --sp-4 (16)
```

This shifts affected paddings/gaps by at most 2px. The composite asymmetric
paddings the prototype uses (`14px 9px`, `11px 18px`) collapse onto scale steps
(`--sp-3 --sp-2`, `--sp-3 --sp-4`).

## §3 Enforcement (harness-first)

Add a `stylelint` rule scoped to `dashboard/src/styles/*-v2.css`:

- Forbid raw `px` in `padding`, `margin`, `gap`, `top/right/bottom/left`,
  `border-radius`, and `width/height` shorthands, except `0` and `1px`/`2px`
  hairline borders.
- Require the value to be a `var(--sp-*)` / `var(--radius-*)` token.

Wire it into the dashboard lint job. Introduce as `warning` for one cycle (so the
existing 609 literals do not hard-block unrelated PRs), then promote to `error`
after §4 migration lands. A warning-only gate that is never promoted is itself a
workaround (telemetry-as-fix); the promotion date is the gate's removal-of-warning
target.

## §4 Migration plan

1. Land §2.1/§2.2 token definitions + `--space-*` alias layer.
2. Remap surfaces to tokens, one file per PR, in ascending off-scale count
   (indicators → primitives → chat-blocks → ide → work → memory → board), each PR
   verified by `vite build` + a screenshot diff review for the rounded surfaces.
3. Promote the stylelint rule to `error`.
4. Remove the `--space-*` alias layer once no surface references it.

## §5 Fleet prompt change

Update the keeper dashboard-surface generation prompt: a new `*-v2.css` must
compose `--sp-*` / `--radius-*` tokens; transcribing prototype pixel values is
rejected by the stylelint gate. This closes the producer so new surfaces do not
re-introduce off-scale px after §4.

## §6 Non-goals

- Re-doing the v2 visual design. The rounding in §2.3 is the only intended visual
  delta, bounded to ±2px.
- Touching color tokens (already correct).
- A full design-system overhaul beyond spacing/radius scale unification.

## §7 Risks

- **Visual regression on merged surfaces.** board-v2/work-v2 shift by ≤2px on
  rounded values. Mitigation: per-file screenshot diff review in §4 step 2.
- **Density composites.** `--sp-stack`/`--sp-section` multiply by `--density`;
  surfaces that hardcoded px bypassed density scaling. Tokenizing restores density
  responsiveness, which may change layout at non-default density — this is a
  correctness improvement but must be checked at each density setting.

## §8 Verification

- `stylelint` reports 0 off-scale px in `*-v2.css` after §4.
- `vite build` exit 0; built bundle retains all surface selectors.
- Screenshot diff per remapped surface shows only the intended ≤2px shifts.
