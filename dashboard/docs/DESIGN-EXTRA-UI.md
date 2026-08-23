# UI the dashboard renders and the design does not

Every other check in `DESIGN-PARITY.md` asks whether the dashboard has what the
design has. This one asks the reverse: **what is on screen that the mock never
draws.** A skin sync that only fills gaps grows the surface forever; the design's
own cleanup plan (`prototypes/keeper-v2/notes/cleanup-plan.md`) exists because
the answer to "what should not be here" is a separate question with separate
evidence.

```bash
node e2e/design-parity-extra-ui.mjs overview:overview keepers:keepers monitor:monitoring …
```

The probe renders both pages, collects the class of every *visible* element,
drops Tailwind utilities and state modifiers, and reports what only the live side
has. It does not judge — a live backend legitimately has connection state, an
emergency stop and empty states that a mock cannot model. It produces the list.

Twelve surfaces, 2026-08-22: **257 distinct components render only on the live
side.** Most are per-surface detail. The ones that recur are below.

## Not candidates — capability the mock cannot hold

| Component | Why it exists |
|---|---|
| `.emergency-stop-control` (8 surfaces) | A real operator control. The mock has no fleet to stop. |
| `.status-text`, `.time-ago` | Live data formatting; the mock's strings are frozen. |
| `.v2-mobile-operator-target` | Touch-target sizing, guarded by `mobile-bottom-reserve.test.ts`. |
| `.skip-link`, `.sr-only` | Keyboard and screen-reader affordances a static mock never needed. |
| `.ov-empty`, `.ov-mini-empty`, `.ov-fus-idle` | Empty states. The mock's data is never empty. |
| `.fl-runtime*`, `.fl-create` | The monitoring row's runtime cell and the create control — the live roster's own columns. |

## Candidates worth a decision

### Two avatar systems — resolved 2026-08-23

`.pixel-avatar` and its five sub-classes rendered on overview, keepers and
monitoring. The design draws a `.sigil` — the two-letter monogram — in the same
places, and the rest of the dashboard already agreed with it: `.sigil` was
rendered by `chat/primitives.ts`, `board/board-surface.ts`, `keeper-badge.ts`,
`ide/ide-editor-ownership.ts` and `v2/primitives-v2.ts`, while `.pixel-avatar`
had exactly one renderer left, `overview/agent-avatar.ts`.

Resolved: `agent-avatar.ts` now renders the same `<Sigil>` primitive
(`common/sigil-chip.ts`, slot via `keeper-badge.ts` `kSlot`/`kSigil`) with a
heartbeat on the old animated statuses. `pixel-avatar.css`,
`config/avatar-palettes.ts` and the overlay vocabulary (activity dot, speech
bubble, blocker ring, signal ring) are deleted; the roster/profile rows carry
that operational context in their own cells. Sizes map to px (`xs` 20 keeps
the fusion dense-list row height previously forced by a `.fus-list` override).

### Shell containers with no design counterpart

`.dashboard-main-scroll` (9 surfaces, `app.ts`), `.v2-surface-host` (4,
`app.ts`), `.ss-surface` (3, `lab.ts` + `overview.ts`). The design's shell is
`.v2-app > .v2-top + .v2-body > .v2-nav + .surf`; these sit between. They may be
load-bearing for the live router, or they may be what is left of the pre-reskin
shell — `main.ts` still carries a "CSS SSOT removal scope" note about exactly
this kind of leftover. Worth tracing before the next sync, since a container that
does nothing still costs a nesting level in every measurement.

### `.v2-top-ops`

The operational cluster in the top bar. The design's top bar carries four chips;
the live one adds connection state, an emergency stop, a verification badge, a
version badge and the tweaks control. `keeper-v2/ops-cluster.css` already exists
to harmonise it to the statchip shape, and `V2-RESKIN-PROGRESS.md` records that
deleting these would be capability loss. Listed for completeness, not as a cut.

## What this check cleared

The design's 2026-08-18 cut asks for wiring vocabulary — field names, enums,
`producer_id`, `trace_id`, `WFQ`, `capacity_backpressure`, `p95`,
`not_observed` — to sit behind a 기술 상세 toggle rather than on the operator's
screen. `design-parity-wiring.mjs` walks the rendered text of thirteen live
surfaces looking for them.

**Zero occurrences in chrome.** Every hit was keeper-authored content: `task_id`
inside a board post's body, `post_id` in a comment, `goal_id` in a chat message,
a task title mentioning `keeper_id`. That is data, not UI, and the cut does not
reach it. A source grep suggests otherwise — `trace_id` appears in 14 files — so
this has to be measured on rendered text or it reads as a violation that is not
there.
