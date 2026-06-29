---
title: RFC-0300 — Dashboard design-token scope consolidation (radius / shadow / type-scale)
---

# RFC-0300: Dashboard design-token scope consolidation

| Field | Value |
|---|---|
| Status | Draft |
| Repo | `jeong-sik/masc` (`dashboard/`) |
| Relates | #22696 (token codegen pipeline restore), #22703 (orphan token CSS removal), #22712 (radius cascade diagnosis in drift baseline), #22723 (chunk B font-size tokenization + ratchet) |
| Evidence | 2026-06-30 cascade investigation during chunk F of the dashboard token-polish backlog |
| Author | dashboard token-polish thread |

## 0. Summary

The dashboard design tokens are not a single SSOT. Several token families
(`--radius-*`, `--shadow-*`, and the `--fs-*` type-scale) are **redefined
across 6–13 CSS scopes** — `tokens.generated.css` (`@theme`/`:root`),
`variables.css` (`:root`), theme blocks (`[data-theme="dark-fantasy"|"paper"|
"styleseed"]`), the active skin (`html[data-skin="v2"]…`), and component
scopes (`.gd-board`, `.wk-surface`, `keeper-v2/*`). Because the scoped blocks
carry higher specificity than `:root`, the value that actually renders in the
default app is **not** the generated value and **not** the `variables.css`
value — it is whichever scoped block wins. The result:

- the override-drift baseline records `:root` values that are *shadowed* and
  never render (documented for radius in #22712);
- some declarations are **dead** (e.g. both `variables.css` `--shadow-card`
  decls are out-specified by `skin-v2.css` in the default skin);
- a value change to the "SSOT" generated token silently does nothing for
  most surfaces.

This RFC proposes a **per-family consolidation**: establish one canonical
scale, keep scoped overrides only where a theme/skin *intentionally* differs,
delete dead declarations, and add a drift ratchet per family. It follows the
pattern already proven in #22723 (font-size: exact-match conversion +
`no-raw-font-size-px.sh` ratchet).

It is explicitly **not** N-of-M patching: each family is its own PR with its
own gate, and the canonical-value decision (§9) is made once, by the design
owner, before any conversion.

## 1. Why consolidation, not per-token edits

Editing a single token value (e.g. `--radius-lg` in `source.ts`) was the
naive chunk-F plan. Investigation (#22712) disproved it: in the default app
(`<html data-skin="v2">`), `skin-v2.css` (`html[data-skin="v2"]:not(...)`,
specificity 0,3,1) outranks `:root` (0,1,0), so `source.ts` never renders for
`--radius-xs/sm/md/lg`. Changing it would alter only the preview surfaces
(which load the generated CSS alone) and *increase* preview↔app divergence.

The same is true for `--shadow-card` (§2.2). So the unit of work is the
**cascade across all scopes**, not one declaration. That is an architectural
decision (which layer is authoritative), hence an RFC.

## 2. Inventory (line-pinned)

### 2.1 Radius — `--radius-{xs,sm,md,lg,xl,pill}`

| Scope (selector) | file | lg | md | sm | xs |
|---|---|---|---|---|---|
| generated `@theme`/`:root` | `tokens.generated.css` | 12 | 6 | 4 | 2 |
| `variables.css` `:root` | `variables.css:364` | 6 | 4 | 3 | — |
| `variables.css` `.gd-board` | `variables.css:660` | — | — | — | 2 |
| `[data-theme="dark-fantasy"]` | `ds-theme-tokens.css:75`, `keeper-v2/colors_and_type.css:60` | 12 | 6 | 4 | 2 |
| `html[data-skin="v2"]:not(...)` | `skin-v2.css:77` | **10** | **6** | **4** | **3** |
| `.wk-surface` | `work-v2.css:18` | — | 6 | 4 | — |
| `keeper-v2` flatten | `keeper-v2/colors_and_type.css:111`, `ds-theme-tokens.css:129` | — | 0 | 0 | 0 |

Default-app rendered scale (skin-v2 wins, `xl`/`pill` fall to `variables.css`
since skin-v2 omits them): **xs 3 / sm 4 / md 6 / lg 10 / xl 8 / pill 9999**.
`--radius-*` is referenced ~637 times.

### 2.2 Shadow — `--shadow-card` (representative; other `--shadow-*` similar)

13 declarations across `tokens.generated.css:349` (`0 1px 4px /.5`),
`variables.css:592` (`:root`, `0 1px 3px /.04`), `variables.css:662`
(`.gd-board`, `0 2px 8px /.35`), `ds-theme-tokens.css` (dark-fantasy/paper/
styleseed), `skin-v2.css:92/184`, `styleseed-*.css`, `keeper-v2/v2.css:81/151`,
`ds-viewer-kit/theme-paper.css:122`.

In the default app, `skin-v2.css:92` (specificity 0,3,1) wins everywhere —
including inside `.gd-board` (`.gd-board` is only 0,1,0) — so **both
`variables.css` `--shadow-card` declarations are dead**. The
override-drift baseline (#22712) captured `0.04` as the "override", which
never renders.

### 2.3 Type-scale — `--fs-*` (font-size)

Resolved structurally by #22723: 1062 of 1672 `font-size: Npx` literals had
an exact `--fs-N` token and were converted; **610 remain** — ~505 fractional
(`10.5/9.5/11.5/12.5px`…) and the rest whole values with no token
(`15/17/18/22px`). Tokenizing them is a **type-scale expansion** decision
(§9.3).

## 3. The failure mode being fixed

1. **`override ≠ rendered`.** The drift baseline assumes `variables.css` is the
   last-winning layer. It is not — scoped blocks outrank `:root`. Any analysis
   or tooling built on that assumption is wrong (corrected in #22712 `_doc`).
2. **Dead declarations.** Out-specified decls (`variables.css` shadow-card,
   the obsolete `--r-4/5/6` removed in #22703) accrete and mislead.
3. **Silent no-op edits.** Changing the generated token does nothing for
   skinned surfaces; the change looks applied (CI green, preview changes) but
   the app is unaffected.

## 4. Goal

Per token family:

- **One canonical scale** declared once, at the layer that actually renders in
  the default app (today: the skin layer for radius/shadow, the generated
  `@theme` for type-scale).
- **Scoped overrides only where a theme/skin intentionally differs** (e.g.
  `paper` flattening shadows, `keeper-v2` flattening radius to 0). Each such
  override carries a one-line comment stating *why* it diverges.
- **No dead declarations.** A decl that is always out-specified is deleted.
- **A drift ratchet** per family (§7), modeled on `no-raw-font-size-px.sh`.

Non-default surfaces (preview, `data-skin` off) must still resolve every token
— canonical values live at a layer they all see (`:root`/`@theme`), and the
skin layer overrides only when present.

## 5. Migration pattern (proven in #22723)

For each family, in its own PR:

1. **Map the cascade** — enumerate every scope's value (§2 tables) and compute
   the default-app rendered value via specificity (or `getComputedStyle`).
2. **Pick canonical** (§9 decision) and place it at the rendering layer.
3. **Convert exact-matches** value-preserving where a token already equals the
   literal; never round (rounding changes rendering — see the 610 fractional
   font-sizes left untouched in #22723).
4. **Delete dead decls** only after confirming they are out-specified in every
   reachable `data-skin`/`data-theme` combination (see §8 risk).
5. **Add a ratchet** (§7) so the converted set stays at zero raw drift.
6. **Verify**: diff is token-only; `tsc` 0; CSS contract tests updated to the
   token form; `tokens:check` passes.

## 6. Phases (each = own PR + own gate)

- **P1 — type-scale tail.** Decide §9.3 (add fractional tokens? round? leave).
  Extend `no-raw-font-size-px.sh` token list as the scale grows. Lowest risk.
- **P2 — shadow.** Resolve §9.2; delete the two dead `variables.css` shadow
  decls; ratchet raw `box-shadow`/`--shadow-*` literals that have a token.
- **P3 — radius.** Resolve §9.1; consolidate the 6 scopes to one canonical
  scale + intentional theme/skin overrides; ratchet raw `border-radius` px
  where a `--radius-*`/`--r-*` token exists. Highest blast radius (~637 refs).

## 7. Drift guard (CI lint, per family)

Generalize `scripts/lint/no-raw-font-size-px.sh` (#22723): for each family,
fail when a raw literal is used where a token of that exact value exists, and
exempt values with no token (the documented design boundary). One `*.sh` +
one `fundamental-check.yml` job per family. Wire into the same workflow.

## 8. Risks / non-goals

- **`skin-v2` permanence.** Deleting `variables.css` fallbacks assumes
  `data-skin="v2"` is always present. `index.html` sets it statically, but if
  a "classic skin" toggle is ever reintroduced, those fallbacks become live.
  P2/P3 must confirm there is no runtime path that removes `data-skin` before
  deleting any `:root` fallback. If unconfirmed, keep the fallback and only
  delete provably-unreachable decls.
- **Non-goal:** changing any *rendered* value. This is a structural
  consolidation; visible pixels stay identical unless §9 explicitly chooses a
  new canonical value, which is called out per-token.
- **Non-goal:** theming redesign. Intentional theme/skin divergence stays.

## 9. Open questions (design-owner decision — values intentionally blank)

These cannot be derived from code; they are design calls. Conversion does not
start until they are answered.

### 9.1 Radius — canonical scale

The default app renders **xs 3 / sm 4 / md 6 / lg 10 / xl 8 / pill 9999**
(skin-v2 + variables fallback). Generated says 2/4/6/12/24/999.

- [ ] Adopt the skin-v2-rendered scale as canonical (no visible change), OR
- [ ] Choose a different canonical scale (specify), OR
- [ ] Keep per-skin radius scales intentionally distinct (document why).

### 9.2 Shadow — canonical `--shadow-card` (and siblings)

Default app renders `skin-v2.css:92` = `0 1px 3px rgba(0,0,0,0.5)`. Generated
= `0 1px 4px rgba(0,0,0,0.5)` (3px vs 4px blur). `variables.css` 0.04 / 0.35
are dead.

- [ ] Canonical shadow-card value: ______ (blur, spread, alpha).
- [ ] Are the dead `variables.css` decls safe to delete? (depends §8 skin
      permanence) — confirm: ______.

### 9.3 Type-scale — the 610 unmapped font-sizes

~505 are fractional (`10.5/9.5/11.5/12.5px`).

- [ ] Add half-step tokens (`--fs-10h` …)? OR
- [ ] Round to nearest existing token (accepts a visible change)? OR
- [ ] Leave raw and exempt (status quo after #22723)?
- [ ] Whole unmapped (`15/17/18/22px`): add tokens or leave?

## 10. Definition of done

- Each family has one canonical scale at the rendering layer, scoped overrides
  commented, dead decls removed (where §8-safe), and a CI ratchet.
- `tokens:check` passes; override-drift baseline entries for consolidated
  families are removed (no longer diverge) or re-annotated as intentional.
- No rendered-pixel change except where §9 explicitly chose one.
